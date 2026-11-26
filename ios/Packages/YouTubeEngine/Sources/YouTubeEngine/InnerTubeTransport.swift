import Foundation
import os

/// One API answer, with what NetPath logs on Android.
public struct APIResponse: Sendable {
    public let data: Data
    public let status: Int
    /// ALPN name from `URLSessionTaskMetrics`: `h2`, `h3`, `http/1.1`; nil if unknown.
    public let protocolName: String?
    public let milliseconds: Int
    public let response: HTTPURLResponse
}

/// The InnerTube side of networking (PRD §4.4): one URLSession for API calls, no cookie jar and no
/// cache (as on Android: `player-http` logs `cookie=n`). HTTP/2 comes from ALPN; every request logs
/// `api client=… status=… ms=… protocol=…`, the counterpart of NetPath's `protocol=h2`.
public final class InnerTubeTransport: Sendable {
    public static let playerURL = URL(string: "https://www.youtube.com/youtubei/v1/player?prettyPrint=false")!
    /// Android bounds `/player` and `/next` to 8 s (RetrofitOkHttpHelper).
    public static let playerTimeout: TimeInterval = 8

    public let session: URLSession
    private let log: @Sendable (String) -> Void

    public init(session: URLSession = InnerTubeTransport.makeSession(), log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.session = session
        self.log = log
    }

    public static func makeSession(_ configuration: URLSessionConfiguration = .default) -> URLSession {
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 20  // Android's shared OkHttp timeout
        return URLSession(configuration: configuration)
    }

    /// `POST /youtubei/v1/player` with Android's headers (VideoInfoApi.java, RetrofitOkHttpHelper):
    /// Content-Type, Origin, the visitor (body and header agree), the client's UA, name id and
    /// version; no Referer, no Cookie, no API key when anonymous.
    public static func playerRequest(_ body: PlayerRequestBody) -> URLRequest {
        var request = URLRequest(url: playerURL, timeoutInterval: playerTimeout)
        request.httpMethod = "POST"
        request.httpBody = body.data
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        if let visitor = body.visitorData { request.setValue(visitor, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        request.setValue(body.client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(body.client.clientNameID, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(body.client.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        return request
    }

    /// Sends and logs one request. `label` is the `client=` field (a client id, or `tv`, `player-js`).
    public func send(_ request: URLRequest, label: String) async throws -> APIResponse {
        let metrics = MetricsCollector()
        let start = ContinuousClock.now
        let path = request.url?.path ?? "?"
        do {
            let (data, response) = try await session.data(for: request, delegate: metrics)
            let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let protocolName = metrics.protocolName
            log("api client=\(label) status=\(http.statusCode) ms=\(milliseconds) protocol=\(protocolName ?? "?") "
                + "bytes=\(data.count) path=\(path)")
            return APIResponse(data: data, status: http.statusCode, protocolName: protocolName,
                               milliseconds: milliseconds, response: http)
        } catch {
            let milliseconds = Int((ContinuousClock.now - start) / .milliseconds(1))
            log("api client=\(label) status=error ms=\(milliseconds) protocol=\(metrics.protocolName ?? "?") "
                + "path=\(path) error=\((error as? URLError)?.code.rawValue ?? -1) \(error.localizedDescription)")
            throw error
        }
    }
}

/// Collects the ALPN protocol of a task's last transaction.
final class MetricsCollector: NSObject, URLSessionTaskDelegate, Sendable {
    private let name = OSAllocatedUnfairLock<String?>(initialState: nil)

    var protocolName: String? { name.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let value = metrics.transactionMetrics.last?.networkProtocolName
        name.withLock { $0 = value }
    }
}
