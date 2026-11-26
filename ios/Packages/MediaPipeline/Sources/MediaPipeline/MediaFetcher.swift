import Foundation
import os

/// One media file on googlevideo. itag, `lastModified` (lmt) and content length (clen) identify the
/// file across answers; the URL (its `id`, signature, host) is per answer.
public struct MediaFile: Sendable, Equatable {
    public var itag: Int
    public var lastModified: String?
    public var contentLength: Int64
    public var url: URL

    public init(itag: Int, lastModified: String?, contentLength: Int64, url: URL) {
        self.itag = itag
        self.lastModified = lastModified
        self.contentLength = contentLength
        self.url = url
    }

    /// The same bytes, whatever the URL (the repoint rule, HANDOFF §34).
    public func isSameFile(as other: MediaFile) -> Bool {
        itag == other.itag && lastModified == other.lastModified && contentLength == other.contentLength
    }
}

/// googlevideo refused a range (HTTP 403, or 401). Routine (PRD §0.4): recover by asking another
/// client for the same itags and `repoint(to:)`; never by retrying this URL.
public struct MediaRefused: Error, Sendable, Equatable {
    public let itag: Int
    /// Where the refused range starts; the caller maps it to stream time (sidx) for the wall rule.
    public let byteOffset: Int64
    public let url: URL
    public let status: Int
}

public enum MediaFetchError: Error, Sendable, Equatable {
    case http(Int)
    /// A 200 for a partial range: the server ignored `Range`.
    case rangeIgnored
    case shortRead(expected: Int, received: Int)
    case notSameFile
    case outOfBounds
    /// Retries spent on timeouts, 5xx or dead hosts; the last cause.
    case exhausted(String)
}

public struct MediaFetcherConfiguration: Sendable {
    /// The first chunk after a start or seek: small, for a fast first frame (US-010).
    public var firstChunk: Int64 = 256 * 1024
    public var maxChunk: Int64 = 2 * 1024 * 1024
    /// Attempts after the first, for timeouts, 5xx and lost connections.
    public var retries = 3
    public var backoff: Duration = .milliseconds(250)
    /// Idle timeout for a host that hasn't answered yet on this network: a dead cache node never
    /// connects, and each wait delays the first frame (D39).
    public var unprovenHostTimeout: TimeInterval = 2
    /// Idle timeout once a host has answered.
    public var timeout: TimeInterval = 15
    /// When an unproven node hasn't answered after this long, its URL's next node starts in parallel
    /// and the first to answer wins (healthy first chunks took 275–374 ms on the iPhone; a dead node
    /// would otherwise cost the whole `unprovenHostTimeout`).
    public var raceDelay: Duration = .milliseconds(750)

    public init() {}
}

/// Byte ranges of one file, the way googlevideo expects them (US-010).
public actor MediaFetcher {
    public private(set) var file: MediaFile
    public nonisolated let configuration: MediaFetcherConfiguration
    private let session: URLSession
    private let hosts: MediaHostBook
    private let network: NetworkWaiting
    private let log: @Sendable (String) -> Void

    public init(file: MediaFile, session: URLSession = MediaFetcher.sharedSession, hosts: MediaHostBook = .shared,
                network: NetworkWaiting = NetworkWatcher.shared, configuration: MediaFetcherConfiguration = .init(),
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.file = file
        self.session = session
        self.hosts = hosts
        self.network = network
        self.configuration = configuration
        self.log = log
    }

    /// One URLSession for media (PRD §4.4): no cookies, no cache.
    public static let sharedSession: URLSession = makeSession()

    public static func makeSession(_ configuration: URLSessionConfiguration = .default) -> URLSession {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }

    /// Points the rest of the file at another answer's URL. Only for the same file (itag, lmt,
    /// clen); the URL's `id` changes per answer. A synthetic wall belongs to the old URL and goes.
    public func repoint(to other: MediaFile) throws {
        guard other.isSameFile(as: file) else { throw MediaFetchError.notSameFile }
        log("media repoint itag=\(file.itag) host=\(file.url.host ?? "?") -> \(other.url.host ?? "?")")
        file = other
        syntheticRefusalFrom = nil
    }

    /// Debug (US-017): this URL refuses (403) every range starting at or past `offset`, as a walled
    /// (visitor, source) pair's links do past 60 s of stream. Cleared by `repoint`.
    public func setSyntheticRefusal(fromByte offset: Int64?) {
        syntheticRefusalFrom = offset
    }
    private var syntheticRefusalFrom: Int64?

    /// Exactly `range` (inclusive), through a `Range` header.
    public func read(_ range: ClosedRange<Int64>) async throws -> Data {
        guard range.lowerBound >= 0, range.upperBound < file.contentLength else { throw MediaFetchError.outOfBounds }
        if let wall = syntheticRefusalFrom, range.lowerBound >= wall {
            log("media itag=\(file.itag) range=\(range.lowerBound)-\(range.upperBound) status=403 synthetic-wall=y")
            throw MediaRefused(itag: file.itag, byteOffset: range.lowerBound, url: file.url, status: 403)
        }
        var failures = 0
        var lastCause = ""
        while true {
            try Task.checkCancellation()
            let url = file.url
            let signature = await network.signature()
            let candidates = await hosts.candidates(for: url, network: signature)
            var connectionFailed = false
            var index = 0
            retry: while index < candidates.count {
                let candidate = candidates[index]
                let backup = !candidate.proven && index + 1 < candidates.count ? candidates[index + 1] : nil
                let outcome = await attempt(range, candidate, racing: backup, network: signature)
                switch outcome {
                case .data(let data):
                    return data
                case .hostsFailed(let cause):
                    // The node(s) never answered: try the URL's other nodes (D39).
                    lastCause = cause
                    connectionFailed = true
                    index += backup == nil ? 1 : 2
                case .linkLost(let cause):
                    lastCause = cause
                    await network.waitUntilSatisfied()
                    break retry
                case .serverError(let status):
                    lastCause = "HTTP \(status)"
                    break retry
                case .fatal(let error):
                    throw error
                }
            }
            if connectionFailed && candidates.count > 1 { lastCause = "every node failed: " + lastCause }
            failures += 1
            guard failures <= configuration.retries else { throw MediaFetchError.exhausted(lastCause) }
            try await Task.sleep(for: configuration.backoff * (1 << (failures - 1)))
        }
    }

    /// The file from `offset` to its end, in chunks that start at `firstChunk` and double up to
    /// `maxChunk`. Pull-based: nothing is fetched until the consumer asks.
    public nonisolated func chunks(from offset: Int64 = 0) -> MediaChunks {
        MediaChunks(fetcher: self, start: offset, first: configuration.firstChunk, max: configuration.maxChunk)
    }

    enum Outcome: Sendable {
        case data(Data)
        case hostsFailed(String)
        case linkLost(String)
        case serverError(Int)
        case fatal(Error)
    }

    /// One candidate, or a race between an unproven candidate and the next one: the backup starts
    /// when the first fails or after `raceDelay`, whichever comes first, and the first answer wins;
    /// the loser is cancelled. (Unstructured tasks plus a resume-once continuation: a task group would
    /// wait for the losing request before returning.)
    private func attempt(_ range: ClosedRange<Int64>, _ candidate: MediaHostBook.Candidate,
                         racing backup: MediaHostBook.Candidate?, network signature: String) async -> Outcome {
        guard let backup else { return await single(range, candidate, network: signature) }
        let primary = Task { await self.single(range, candidate, network: signature) }
        let delay = configuration.raceDelay

        // Phase 1: the primary alone, until it answers or the delay passes.
        let early = await Self.firstOf([primary], orAfter: delay)?.outcome
        switch early {
        case .hostsFailed(let cause)?:
            let second = await single(range, backup, network: signature)
            if case .hostsFailed(let other) = second { return .hostsFailed(cause + "; " + other) }
            return second
        case let outcome?:
            return outcome
        case nil:
            break
        }

        // Phase 2: the primary is still silent; the backup joins.
        log("media race itag=\(file.itag) range=\(range.lowerBound)-\(range.upperBound) "
            + "after=\(Int(delay / .milliseconds(1)))ms backup=\(backup.url.host ?? "?")")
        let second = Task { await self.single(range, backup, network: signature) }
        let result = await Self.firstOf([primary, second], orAfter: nil)
        primary.cancel()
        second.cancel()
        if result?.winner == 1, case .data? = result?.outcome {
            // Still silent when its alternate had answered: dead for this network, so the next URL on
            // this node's cluster starts with its alternates instead of racing again.
            await hosts.markDead(candidate.node, network: signature)
        }
        return result?.outcome ?? .hostsFailed("no answer")
    }

    /// The first outcome that isn't a host failure among `tasks` (with its index), or the joined host
    /// failures once all have failed; nil if `delay` passes first (the tasks keep running).
    static func firstOf(_ tasks: [Task<Outcome, Never>], orAfter delay: Duration?) async -> (outcome: Outcome, winner: Int?)? {
        let once = ResumeOnce<(outcome: Outcome, winner: Int?)?>()
        let failures = OSAllocatedUnfairLock(initialState: [String]())
        return await withCheckedContinuation { continuation in
            once.arm(continuation)
            for (index, task) in tasks.enumerated() {
                Task {
                    let outcome = await task.value
                    if case .hostsFailed(let cause) = outcome {
                        let all = failures.withLock { list -> [String]? in
                            list.append(cause)
                            return list.count == tasks.count ? list : nil
                        }
                        if let all { once.resume((.hostsFailed(all.joined(separator: "; ")), nil)) }
                    } else {
                        once.resume((outcome, index))
                    }
                }
            }
            if let delay {
                Task {
                    try? await Task.sleep(for: delay)
                    once.resume(nil)
                }
            }
        }
    }

    private func single(_ range: ClosedRange<Int64>, _ candidate: MediaHostBook.Candidate, network signature: String) async -> Outcome {
        do {
            return .data(try await fetch(range, from: candidate.url, node: candidate.node, proven: candidate.proven,
                                         network: signature))
        } catch let error as URLError where Self.isHostFailure(error) {
            await hosts.markDead(candidate.node, network: signature)
            return .hostsFailed("\(error.code.rawValue) at \(candidate.url.host ?? "?")")
        } catch let error as URLError where error.code == .cancelled {
            return .hostsFailed("cancelled at \(candidate.url.host ?? "?")")
        } catch let error as URLError where Self.isLinkFailure(error) {
            return .linkLost("\(error.code.rawValue)")
        } catch MediaFetchError.http(let status) where (500...599).contains(status) {
            return .serverError(status)
        } catch {
            return .fatal(error)
        }
    }

    private func fetch(_ range: ClosedRange<Int64>, from url: URL, node: String?, proven: Bool,
                       network: String) async throws -> Data {
        var request = URLRequest(url: url, timeoutInterval: proven ? configuration.timeout : configuration.unprovenHostTimeout)
        request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range")
        request.assumesHTTP3Capable = true
        let metrics = MediaMetrics()
        let start = ContinuousClock.now
        let line = { (status: String) in
            let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
            return "media itag=\(self.file.itag) range=\(range.lowerBound)-\(range.upperBound) status=\(status) ms=\(ms) "
                + "protocol=\(metrics.protocolName ?? "?") host=\(url.host ?? "?") proven=\(proven ? "y" : "n")"
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: metrics)
        } catch {
            log(line("error-\((error as? URLError)?.code.rawValue ?? -1)"))
            throw error
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        log(line("\(status)") + " bytes=\(data.count)")
        await hosts.markAlive(node, network: network)
        switch status {
        case 206:
            let expected = Int(range.upperBound - range.lowerBound + 1)
            guard data.count == expected else { throw MediaFetchError.shortRead(expected: expected, received: data.count) }
            return data
        case 200:
            // Only acceptable when the range was the whole file.
            guard range.lowerBound == 0, Int64(data.count) == file.contentLength else { throw MediaFetchError.rangeIgnored }
            return data.subdata(in: 0..<Int(range.upperBound + 1))
        case 401, 403:
            throw MediaRefused(itag: file.itag, byteOffset: range.lowerBound, url: file.url, status: status)
        default:
            throw MediaFetchError.http(status)
        }
    }

    /// The host never answered: another node may.
    static func isHostFailure(_ error: URLError) -> Bool {
        [.timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .secureConnectionFailed].contains(error.code)
    }

    /// The device lost its network: wait for a path, then try again.
    static func isLinkFailure(_ error: URLError) -> Bool {
        [.networkConnectionLost, .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff].contains(error.code)
    }
}

/// Chunks of a file from an offset; see `MediaFetcher.chunks(from:)`.
public struct MediaChunks: AsyncSequence {
    public struct Chunk: Sendable, Equatable {
        public let offset: Int64
        public let data: Data
    }

    let fetcher: MediaFetcher
    let start: Int64
    let first: Int64
    let maxSize: Int64

    init(fetcher: MediaFetcher, start: Int64, first: Int64, max: Int64) {
        self.fetcher = fetcher
        self.start = start
        self.first = first
        maxSize = max
    }

    public func makeAsyncIterator() -> Iterator { Iterator(fetcher: fetcher, position: start, size: first, maxSize: maxSize) }

    public struct Iterator: AsyncIteratorProtocol {
        let fetcher: MediaFetcher
        var position: Int64
        var size: Int64
        let maxSize: Int64

        public mutating func next() async throws -> Chunk? {
            let length = await fetcher.file.contentLength
            guard position < length else { return nil }
            let end = Swift.min(position + size, length) - 1
            let chunk = Chunk(offset: position, data: try await fetcher.read(position...end))
            position = end + 1
            size = Swift.min(size * 2, maxSize)
            return chunk
        }
    }
}

/// A continuation resumed by the first caller only.
final class ResumeOnce<Value: Sendable>: Sendable {
    private let continuation = OSAllocatedUnfairLock<CheckedContinuation<Value, Never>?>(initialState: nil)

    func arm(_ value: CheckedContinuation<Value, Never>) { continuation.withLock { $0 = value } }

    func resume(_ value: Value) {
        let taken = continuation.withLock { current -> CheckedContinuation<Value, Never>? in
            defer { current = nil }
            return current
        }
        taken?.resume(returning: value)
    }
}

/// Collects the ALPN protocol of a media request.
final class MediaMetrics: NSObject, URLSessionTaskDelegate, Sendable {
    private let name = OSAllocatedUnfairLock<String?>(initialState: nil)
    var protocolName: String? { name.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let value = metrics.transactionMetrics.last?.networkProtocolName
        name.withLock { $0 = value }
    }
}
