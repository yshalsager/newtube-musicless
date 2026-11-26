import Foundation
import os
import Testing
@testable import YouTubeEngine

/// US-008: the visitor from youtube.com/tv (10 h, cookie replay), the signature timestamp, and the
/// transport's headers and log line.
@Suite struct VisitorIdentityTests {
    static let page = #"<html><script>window.environment = {"player_url":"\/s\/player\/7460dd14\/tv-player-ias.vflset\/tv-player-ias.js","visitorData":"CgtWSVNJVE9SX0lEKOGv0rAG%3D%3D","other":1}</script></html>"#
    static let script = "var a=1;var b={signatureTimestamp:20717,c:2};"

    @Test func visitorIsFetchedPersistedAndReusedFor10Hours() async throws {
        let stub = Stub()
        stub.serve { request in
            if request.url?.path == "/tv" {
                return .init(status: 200, headers: ["Set-Cookie": "VISITOR_INFO1_LIVE=abc123; Path=/; Secure"], body: Data(Self.page.utf8))
            }
            return .init(status: 200, headers: [:], body: Data(Self.script.utf8))
        }
        let clock = Clock()
        let store = FileManager.default.temporaryDirectory.appendingPathComponent("visitor-\(UUID().uuidString).json")
        let identity = VisitorIdentity(transport: stub.transport, storeURL: store, now: clock.now)

        let first = try await identity.current()
        #expect(first.visitorData == "CgtWSVNJVE9SX0lEKOGv0rAG%3D%3D")
        #expect(first.playerURL == "https://www.youtube.com/s/player/7460dd14/tv-player-ias.vflset/tv-player-ias.js")
        #expect(first.cookie == "VISITOR_INFO1_LIVE=abc123")
        #expect(first.shortVisitor == "CgtWSVNJVE")
        let tvRequest = try #require(stub.requests.first)
        #expect(tvRequest.value(forHTTPHeaderField: "User-Agent") == VisitorIdentity.fireTVUserAgent)
        #expect(tvRequest.value(forHTTPHeaderField: "Cookie") == VisitorIdentity.consentCookie)

        clock.advance(9 * 3600)
        _ = try await identity.current()
        #expect(stub.requests.count == 1, "still fresh at 9 h")

        // Persisted: a new instance (an app restart) doesn't fetch either.
        let restarted = VisitorIdentity(transport: stub.transport, storeURL: store, now: clock.now)
        #expect(try await restarted.current() == first)
        #expect(stub.requests.count == 1)

        clock.advance(2 * 3600)
        _ = try await restarted.current()
        #expect(stub.requests.count == 2, "refreshed after 10 h")
        let replay = try #require(stub.requests.last?.value(forHTTPHeaderField: "Cookie"))
        #expect(replay == "VISITOR_INFO1_LIVE=abc123; " + VisitorIdentity.consentCookie, "the stored visitor is replayed")
    }

    @Test func signatureTimestampIsFetchedOncePerPlayer() async throws {
        let stub = Stub()
        stub.serve { request in
            request.url?.path == "/tv" ? .init(status: 200, headers: [:], body: Data(Self.page.utf8))
                : .init(status: 200, headers: [:], body: Data(Self.script.utf8))
        }
        let identity = VisitorIdentity(transport: stub.transport, storeURL: nil)
        #expect(await identity.signatureTimestamp() == 20717)
        #expect(await identity.signatureTimestamp() == 20717)
        #expect(stub.requests.filter { $0.url?.path.hasSuffix(".js") == true }.count == 1)
    }

    @Test func missingTimestampIsMinusOne() async {
        let stub = Stub()
        stub.serve { request in
            request.url?.path == "/tv" ? .init(status: 200, headers: [:], body: Data(Self.page.utf8))
                : .init(status: 200, headers: [:], body: Data("no timestamp here".utf8))
        }
        #expect(await VisitorIdentity(transport: stub.transport, storeURL: nil).signatureTimestamp() == -1)
    }

    @Test func pageWithoutVisitorDataFails() async {
        let stub = Stub()
        stub.serve { _ in .init(status: 503, headers: [:], body: Data("busy".utf8)) }
        await #expect(throws: VisitorError.self) {
            try await VisitorIdentity(transport: stub.transport, storeURL: nil).current()
        }
    }

    @Test func storedVisitorSurvivesAnAnswerWithoutOne() {
        // AppServiceInt.nextVisitorCookie's three cases.
        #expect(VisitorIdentity.nextVisitorCookie(stored: "VISITOR_INFO1_LIVE=old; YSC=1", received: "YSC=2; VISITOR_PRIVACY_METADATA=x")
                == "YSC=2; VISITOR_PRIVACY_METADATA=x; VISITOR_INFO1_LIVE=old")
        #expect(VisitorIdentity.nextVisitorCookie(stored: "VISITOR_INFO1_LIVE=old", received: "VISITOR_INFO1_LIVE=new; YSC=2")
                == "VISITOR_INFO1_LIVE=new; YSC=2")
        #expect(VisitorIdentity.nextVisitorCookie(stored: nil, received: "YSC=2") == "YSC=2")
        #expect(VisitorIdentity.nextVisitorCookie(stored: "VISITOR_INFO1_LIVE=old", received: nil) == "VISITOR_INFO1_LIVE=old")
        #expect(VisitorIdentity.nextVisitorCookie(stored: "VISITOR_INFO1_LIVE=old", received: "VISITOR_INFO1_LIVE=")
                == "VISITOR_INFO1_LIVE=old", "an empty id is no id")
    }

    @Test func timestampRegexAndURLTidying() {
        #expect(VisitorIdentity.signatureTimestamp(in: "x={signatureTimestamp:20717}") == 20717)
        #expect(VisitorIdentity.signatureTimestamp(in: "signatureTimestamp=20718;") == 20718)
        #expect(VisitorIdentity.signatureTimestamp(in: "nothing") == nil)
        #expect(VisitorIdentity.tidyURL(#"\/s\/player\/ab\/base.js"#) == "https://www.youtube.com/s/player/ab/base.js")
        #expect(VisitorIdentity.playerID("https://www.youtube.com/s/player/7460dd14/tv-player-ias.vflset/x.js") == "7460dd14")
    }

    @Test func playerRequestCarriesAndroidsHeadersAndLogsTheProtocol() async throws {
        let stub = Stub()
        stub.serve { _ in .init(status: 200, headers: [:], body: Data(#"{"playabilityStatus":{"status":"OK"}}"#.utf8)) }
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let transport = InnerTubeTransport(session: stub.transport.session, log: { line in lines.withLock { $0.append(line) } })
        let body = PlayerRequestBodyTests.body()
        let answer = try await transport.send(InnerTubeTransport.playerRequest(body), label: "VISIONOS")
        #expect(answer.status == 200)

        let request = try #require(stub.requests.first)
        #expect(request.url?.absoluteString == "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")
        #expect(request.httpMethod == "POST")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Origin") == "https://www.youtube.com")
        #expect(request.value(forHTTPHeaderField: "X-Goog-Visitor-Id") == "CgtWSVNJVE9SX0lEKOGv0rAG")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == ClientProfile.visionOS.userAgent)
        #expect(request.value(forHTTPHeaderField: "X-Youtube-Client-Name") == "101")
        #expect(request.value(forHTTPHeaderField: "X-Youtube-Client-Version") == "1.02")
        #expect(request.value(forHTTPHeaderField: "Referer") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.timeoutInterval == 8)

        let line = try #require(lines.withLock { $0 }.first)
        #expect(line.hasPrefix("api client=VISIONOS status=200 ms="))
        #expect(line.contains(" protocol="))
    }
}

// MARK: - Test helpers

final class Clock: Sendable {
    private let time = OSAllocatedUnfairLock(initialState: Date(timeIntervalSince1970: 1_790_000_000))
    var now: @Sendable () -> Date { { [time] in time.withLock { $0 } } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
}

/// A stub server for one test: its own host-independent registry entry, keyed by a session id.
final class Stub: Sendable {
    struct Reply: Sendable {
        let status: Int
        let headers: [String: String]
        let body: Data
    }

    let id = UUID().uuidString
    let transport: InnerTubeTransport

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub-Id": id]
        transport = InnerTubeTransport(session: InnerTubeTransport.makeSession(configuration))
    }

    func serve(_ handler: @escaping @Sendable (URLRequest) -> Reply) { StubProtocol.handlers.withLock { $0[id] = handler } }
    var requests: [URLRequest] { StubProtocol.requests.withLock { $0[id] ?? [] } }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let handlers = OSAllocatedUnfairLock(initialState: [String: @Sendable (URLRequest) -> Stub.Reply]())
    static let requests = OSAllocatedUnfairLock(initialState: [String: [URLRequest]]())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Stub-Id") ?? ""
        var copy = request
        if copy.httpBody == nil, let stream = request.httpBodyStream { copy.httpBody = Self.read(stream) }
        let recorded = copy
        Self.requests.withLock { $0[id, default: []].append(recorded) }
        guard let handler = Self.handlers.withLock({ $0[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let reply = handler(recorded)
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
