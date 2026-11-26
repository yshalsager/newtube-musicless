import Foundation
import os
import Testing
@testable import MediaPipeline

/// US-010: the media fetcher against a stub googlevideo.
@Suite struct MediaFetcherTests {
    static let body: Data = Data((0..<(5 * 1024 * 1024 + 12_345)).map { UInt8(truncatingIfNeeded: $0 * 7 + $0 / 251) })
    static let goodURL = URL(string: "https://rr1---sn-edge0aaa.googlevideo.com/videoplayback?itag=140&clen=\(body.count)&lmt=1700&mn=sn-edge0aaa")!

    static func file(_ url: URL = goodURL, lmt: String = "1700") -> MediaFile {
        MediaFile(itag: 140, lastModified: lmt, contentLength: Int64(body.count), url: url)
    }

    static func fast() -> MediaFetcherConfiguration {
        var configuration = MediaFetcherConfiguration()
        configuration.backoff = .milliseconds(1)
        return configuration
    }

    @Test func rangesUseTheHeaderAndChunksGrowFrom256KiBTo2MiB() async throws {
        let stub = MediaStub()
        stub.serve { request in .partial(Self.body, request) }
        let fetcher = MediaFetcher(file: Self.file(), session: stub.session, hosts: MediaHostBook(), network: FakeNetwork(),
                                   configuration: Self.fast())
        var assembled = Data(), sizes: [Int] = []
        for try await chunk in fetcher.chunks() {
            #expect(chunk.offset == Int64(assembled.count))
            assembled.append(chunk.data)
            sizes.append(chunk.data.count)
        }
        #expect(assembled == Self.body)
        let kib = 1024
        #expect(Array(sizes.prefix(4)) == [256 * kib, 512 * kib, 1024 * kib, 2048 * kib])
        #expect(sizes.dropFirst(3).allSatisfy { $0 <= 2048 * kib })
        for request in stub.requests {
            #expect(request.value(forHTTPHeaderField: "Range")?.hasPrefix("bytes=") == true)
            #expect(request.url?.query?.contains("range=") == false, "never &range= (PRD §0.4)")
            #expect(request.assumesHTTP3Capable)
        }
    }

    @Test func forbiddenIsTypedAndNeverRetriedOnTheSameURL() async throws {
        let stub = MediaStub()
        stub.serve { _ in .status(403) }
        let fetcher = MediaFetcher(file: Self.file(), session: stub.session, hosts: MediaHostBook(), network: FakeNetwork(),
                                   configuration: Self.fast())
        await #expect(throws: MediaRefused(itag: 140, byteOffset: 1_000, url: Self.goodURL, status: 403)) {
            _ = try await fetcher.read(1_000...1_999)
        }
        #expect(stub.requests.count == 1)
    }

    @Test func serverErrorsAreRetriedWithBackoffThenGiveUp() async throws {
        let stub = MediaStub()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        stub.serve { request in
            let call = calls.withLock { value -> Int in value += 1; return value }
            return call <= 2 ? .status(503) : .partial(Self.body, request)
        }
        let fetcher = MediaFetcher(file: Self.file(), session: stub.session, hosts: MediaHostBook(), network: FakeNetwork(),
                                   configuration: Self.fast())
        #expect(try await fetcher.read(0...99) == Self.body.prefix(100))
        #expect(stub.requests.count == 3)

        let failing = MediaStub()
        failing.serve { _ in .status(502) }
        let doomed = MediaFetcher(file: Self.file(), session: failing.session, hosts: MediaHostBook(), network: FakeNetwork(),
                                  configuration: Self.fast())
        await #expect(throws: MediaFetchError.exhausted("HTTP 502")) { _ = try await doomed.read(0...99) }
        #expect(failing.requests.count == 1 + Self.fast().retries)
    }

    @Test func repointAcceptsOnlyTheSameFileAndResumesAtTheRefusedOffset() async throws {
        let refusedURL = Self.goodURL
        let freshURL = URL(string: "https://rr1---sn-edge0aaa.googlevideo.com/videoplayback?itag=140&id=fresh&mn=sn-edge0aaa")!
        let stub = MediaStub()
        stub.serve { request in
            let start = MediaStub.rangeStart(request) ?? 0
            if request.url?.query?.contains("id=fresh") == true { return .partial(Self.body, request) }
            return start >= 1_000_000 ? .status(403) : .partial(Self.body, request)  // a wall past ~1 MB
        }
        let fetcher = MediaFetcher(file: Self.file(refusedURL), session: stub.session, hosts: MediaHostBook(),
                                   network: FakeNetwork(), configuration: Self.fast())
        var assembled = Data()
        do {
            for try await chunk in fetcher.chunks() { assembled.append(chunk.data) }
            Issue.record("expected a refusal")
        } catch let refused as MediaRefused {
            #expect(refused.byteOffset == Int64(assembled.count))
            await #expect(throws: MediaFetchError.notSameFile) { try await fetcher.repoint(to: Self.file(freshURL, lmt: "1701")) }
            try await fetcher.repoint(to: Self.file(freshURL))
            for try await chunk in fetcher.chunks(from: refused.byteOffset) { assembled.append(chunk.data) }
        }
        #expect(assembled == Self.body, "no gap, no overlap across the repoint")
        #expect(stub.requests.filter { $0.url?.query?.contains("id=fresh") == true }.count >= 1)
    }

    @Test func aDeadNodeFallsBackToTheURLsAlternatesAndIsRemembered() async throws {
        let dead = "rr5---sn-isp1-aaaa.googlevideo.com"
        let url = URL(string: "https://\(dead)/videoplayback?itag=140&mn=sn-isp1-aaaa%2Csn-edge1bbb&fvip=4")!
        let stub = MediaStub()
        stub.serve { request in request.url?.host == dead || request.url?.host?.contains("sn-isp1-") == true
            ? .failure(.timedOut) : .partial(Self.body, request) }
        let book = MediaHostBook()
        let fetcher = MediaFetcher(file: Self.file(url), session: stub.session, hosts: book, network: FakeNetwork(),
                                   configuration: Self.fast())
        #expect(try await fetcher.read(0...99) == Self.body.prefix(100))
        #expect(stub.requests.map { $0.url!.host! } == [dead, "rr5---sn-edge1bbb.googlevideo.com"])
        #expect(stub.requests.first?.timeoutInterval == 2, "an unproven host gets the short timeout")

        _ = try await fetcher.read(100...199)
        #expect(stub.requests.last?.url?.host == "rr5---sn-edge1bbb.googlevideo.com")
        #expect(stub.requests.count == 3, "the dead node isn't asked again")
        #expect(stub.requests.last?.timeoutInterval == 15, "a proven host gets the normal timeout")

        // Another node of the same cluster: its alternate goes first.
        let sibling = URL(string: "https://rr2---sn-isp1-cccc.googlevideo.com/videoplayback?itag=140&mn=sn-isp1-cccc%2Csn-edge2ddd")!
        let second = MediaFetcher(file: Self.file(sibling), session: stub.session, hosts: book, network: FakeNetwork(),
                                  configuration: Self.fast())
        _ = try await second.read(0...99)
        #expect(stub.requests.last?.url?.host == "rr2---sn-edge2ddd.googlevideo.com")
        #expect(!stub.requests.contains { $0.url?.host == "rr2---sn-isp1-cccc.googlevideo.com" })
    }

    @Test func aHangingNodeIsRacedByItsAlternateAfterTheDelay() async throws {
        let hanging = "rr3---sn-isp2-eeee.googlevideo.com"
        let url = URL(string: "https://\(hanging)/videoplayback?itag=140&mn=sn-isp2-eeee%2Csn-edge3fff")!
        let stub = MediaStub()
        stub.serve { request in request.url?.host == hanging ? .delayed(1.5, .partial(Self.body, request)) : .partial(Self.body, request) }
        var configuration = Self.fast()
        configuration.raceDelay = .milliseconds(200)
        let fetcher = MediaFetcher(file: Self.file(url), session: stub.session, hosts: MediaHostBook(), network: FakeNetwork(),
                                   configuration: configuration)
        let start = ContinuousClock.now
        #expect(try await fetcher.read(0...99) == Self.body.prefix(100))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed < .milliseconds(1_000), "the backup won (\(elapsed))")
        #expect(stub.requests.map { $0.url!.host! } == [hanging, "rr3---sn-edge3fff.googlevideo.com"])
        // The backup proved itself: the next read goes to it first, no race.
        _ = try await fetcher.read(100...199)
        #expect(stub.requests.last?.url?.host == "rr3---sn-edge3fff.googlevideo.com")
        #expect(stub.requests.count == 3)
        // The silent node counts as dead: a sibling in its cluster starts with its own alternate.
        let sibling = URL(string: "https://rr4---sn-isp2-gggg.googlevideo.com/videoplayback?itag=140&mn=sn-isp2-gggg%2Csn-edge4hhh")!
        try await fetcher.repoint(to: Self.file(sibling))
        _ = try await fetcher.read(200...299)
        #expect(stub.requests.last?.url?.host == "rr4---sn-edge4hhh.googlevideo.com")
        #expect(!stub.requests.contains { $0.url?.host == "rr4---sn-isp2-gggg.googlevideo.com" })
    }

    @Test func anotherNetworkForgetsTheDeadNodes() async throws {
        let book = MediaHostBook()
        let url = URL(string: "https://rr5---sn-isp1-aaaa.googlevideo.com/videoplayback?mn=sn-isp1-aaaa%2Csn-edge1bbb")!
        await book.markDead("sn-isp1-aaaa", network: "wifi")
        #expect(await book.candidates(for: url, network: "wifi").first?.node == "sn-edge1bbb")
        #expect(await book.candidates(for: url, network: "cellular").first?.node == "sn-isp1-aaaa")
    }

    @Test func aLostLinkWaitsForTheNetworkThenResumes() async throws {
        let stub = MediaStub()
        let calls = OSAllocatedUnfairLock(initialState: 0)
        stub.serve { request in
            calls.withLock { value -> Int in value += 1; return value } == 1 ? .failure(.networkConnectionLost) : .partial(Self.body, request)
        }
        let network = FakeNetwork()
        let fetcher = MediaFetcher(file: Self.file(), session: stub.session, hosts: MediaHostBook(), network: network,
                                   configuration: Self.fast())
        #expect(try await fetcher.read(0...99) == Self.body.prefix(100))
        #expect(await network.waits == 1)
    }

    @Test func aServerIgnoringRangeIsAnErrorUnlessTheWholeFileWasAsked() async throws {
        let stub = MediaStub()
        stub.serve { _ in .whole(Self.body) }
        let fetcher = MediaFetcher(file: Self.file(), session: stub.session, hosts: MediaHostBook(), network: FakeNetwork(),
                                   configuration: Self.fast())
        await #expect(throws: MediaFetchError.rangeIgnored) { _ = try await fetcher.read(10...99) }
        #expect(try await fetcher.read(0...Int64(Self.body.count - 1)) == Self.body)
        await #expect(throws: MediaFetchError.outOfBounds) { _ = try await fetcher.read(0...Int64(Self.body.count)) }
    }
}

// MARK: - Stub googlevideo

actor FakeNetwork: NetworkWaiting {
    var current = "test"
    private(set) var waits = 0
    func signature() -> String { current }
    func waitUntilSatisfied() { waits += 1 }
}

final class MediaStub: Sendable {
    enum Reply: Sendable {
        case partial(Data, URLRequest)
        case whole(Data)
        case status(Int)
        case failure(URLError.Code)
        /// Answers `reply` after `seconds`, unless the request is cancelled first.
        indirect case delayed(TimeInterval, Reply)
    }

    let id = UUID().uuidString
    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MediaStubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub-Id": id]
        session = MediaFetcher.makeSession(configuration)
    }

    func serve(_ handler: @escaping @Sendable (URLRequest) -> Reply) { MediaStubProtocol.handlers.withLock { $0[id] = handler } }
    var requests: [URLRequest] { MediaStubProtocol.requests.withLock { $0[id] ?? [] } }

    static func rangeStart(_ request: URLRequest) -> Int64? { parseRange(request)?.lowerBound }

    static func parseRange(_ request: URLRequest) -> ClosedRange<Int64>? {
        guard let header = request.value(forHTTPHeaderField: "Range"), header.hasPrefix("bytes=") else { return nil }
        let parts = header.dropFirst(6).split(separator: "-").compactMap { Int64($0) }
        return parts.count == 2 ? parts[0]...parts[1] : nil
    }
}

final class MediaStubProtocol: URLProtocol, @unchecked Sendable {
    static let handlers = OSAllocatedUnfairLock(initialState: [String: @Sendable (URLRequest) -> MediaStub.Reply]())
    static let requests = OSAllocatedUnfairLock(initialState: [String: [URLRequest]]())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private let stopped = OSAllocatedUnfairLock(initialState: false)

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Stub-Id") ?? ""
        let recorded = request
        Self.requests.withLock { $0[id, default: []].append(recorded) }
        guard let handler = Self.handlers.withLock({ $0[id] }), let url = request.url else {
            return client!.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
        }
        deliver(handler(recorded), url: url)
    }

    private func deliver(_ reply: MediaStub.Reply, url: URL) {
        if stopped.withLock({ $0 }) { return }
        switch reply {
        case .delayed(let seconds, let later):
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { self.deliver(later, url: url) }
        case .failure(let code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .status(let status):
            respond(url, status: status, headers: [:], body: Data())
        case .whole(let data):
            respond(url, status: 200, headers: ["Content-Length": "\(data.count)"], body: data)
        case .partial(let data, let request):
            guard let range = MediaStub.parseRange(request), range.upperBound < data.count else {
                return respond(url, status: 416, headers: [:], body: Data())
            }
            let slice = data.subdata(in: Int(range.lowerBound)..<Int(range.upperBound + 1))
            respond(url, status: 206, headers: ["Content-Range": "bytes \(range.lowerBound)-\(range.upperBound)/\(data.count)",
                                               "Content-Length": "\(slice.count)"], body: slice)
        }
    }

    private func respond(_ url: URL, status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() { stopped.withLock { $0 = true } }
}
