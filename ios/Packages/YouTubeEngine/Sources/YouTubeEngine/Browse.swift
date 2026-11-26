import Foundation

extension ClientProfile {
    /// The TV client that browse-shaped requests use: search, channels, feeds (AppClient.TV,
    /// Constants.kt `CLIENTS.TV`, the Cobalt UA, `POST_DATA_BROWSE_TV`). Never a /player source.
    public static let tv = ClientProfile(
        id: "TV", clientName: "TVHTML5", clientVersion: "7.20260707.07.00", clientNameID: "7",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)",
        clientScreen: "WATCH", deviceFields: "", supportXhr: false, isEmbedded: false, attemptTimeout: .seconds(20))
}

public struct BrowseError: Error, CustomStringConvertible, Equatable {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Browse-shaped InnerTube requests over the TV client (US-019+): MediaServiceCore's
/// `PostDataHelper.createQueryTV` body (JSON_POST_DATA_BASE with POST_DATA_BROWSE_TV) and the
/// visitor in both body and header, as `SearchApi.getSearchResult(query, visitorData)` sends it.
public struct BrowseClient: Sendable {
    private let transport: InnerTubeTransport
    private let visitor: @Sendable () async -> String?
    private let locale: @Sendable () -> RequestLocale
    /// Signed in: the account (`Bearer …`). TV-shaped browse requests may carry it (FR-17).
    private let authorization: @Sendable () async -> String?
    let log: @Sendable (String) -> Void

    public init(transport: InnerTubeTransport, visitor: @escaping @Sendable () async -> String?,
                authorization: @escaping @Sendable () async -> String? = { nil },
                locale: @escaping @Sendable () -> RequestLocale = { .current }, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transport = transport
        self.visitor = visitor
        self.authorization = authorization
        self.locale = locale
        self.log = log
    }

    /// `/search` for `query` (SearchApiHelper.getSearchQuery without filters).
    public func search(_ query: String) async throws -> FeedPage {
        let start = ContinuousClock.now
        let page = try FeedParser.page(try await post("search", ["query": query]))
        logPage("search", page, start: start, extra: "queryLength=\(query.count)")
        return page
    }

    /// The next page of a search (SearchApiHelper.getContinuationQuery).
    public func continueSearch(_ token: String) async throws -> FeedPage {
        let start = ContinuousClock.now
        let page = try FeedParser.continuationPage(try await post("search", ["continuation": token]))
        logPage("search-continuation", page, start: start, extra: nil)
        return page
    }

    /// `/next` for a video (WatchNextApiHelper.getWatchNextQuery over the TV client).
    public func next(videoID: String) async throws -> WatchNext {
        let start = ContinuousClock.now
        let next = try FeedParser.watchNext(try await post("next", ["videoId": videoID]), videoID: videoID)
        log("browse next video=\(videoID) related=\(next.related.items.count) continuation=\(next.related.continuation == nil ? "n" : "y") "
            + "description=\(next.description == nil ? "n" : "y") comments=\(next.commentsToken == nil ? "n" : "y") "
            + "ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
        return next
    }

    /// More related videos (WatchNextService.continueGroup: the browse continuation body on `/next`).
    public func continueNext(_ token: String) async throws -> FeedPage {
        let start = ContinuousClock.now
        let page = try FeedParser.continuationPage(try await post("next", ["continuation": token]))
        logPage("next-continuation", page, start: start, extra: nil)
        return page
    }

    /// One POST, retried once on a transport error or a 5xx (SearchService2 retries with a cloned
    /// call). A 4xx is an answer, not retried.
    func post(_ endpoint: String, _ fields: [String: String], extra: [String: Any] = [:], signedIn: Bool = false) async throws -> Data {
        let visitorData = await visitor()
        var request = Self.request(endpoint, fields: fields, visitorData: visitorData, locale: locale(), extra: extra)
        if let authorization = await authorization() {
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
        } else if signedIn {
            throw BrowseError("signed out")
        }
        var lastError: any Error = BrowseError("no attempt")
        for attempt in 1...2 {
            do {
                let response = try await transport.send(request, label: ClientProfile.tv.id)
                if response.status == 200 { return response.data }
                lastError = BrowseError("status \(response.status)")
                if response.status < 500 { break }
            } catch {
                lastError = error
            }
            if attempt == 1 { log("browse retry endpoint=\(endpoint) error=\(lastError)") }
        }
        throw lastError
    }

    public static func request(_ endpoint: String, fields: [String: String], visitorData: String?, locale: RequestLocale,
                               extra: [String: Any] = [:]) -> URLRequest {
        let client = ClientProfile.tv
        var request = URLRequest(url: URL(string: "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false")!,
                                 timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpBody = body(fields: fields, visitorData: visitorData, locale: locale, extra: extra)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        request.setValue("https://www.youtube.com/tv", forHTTPHeaderField: "Referer")
        request.setValue(client.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(client.clientNameID, forHTTPHeaderField: "X-Youtube-Client-Name")
        request.setValue(client.clientVersion, forHTTPHeaderField: "X-Youtube-Client-Version")
        if let visitorData { request.setValue(visitorData, forHTTPHeaderField: "X-Goog-Visitor-Id") }
        return request
    }

    /// JSON_POST_DATA_BASE for AppClient.TV's browse template, plus the request's own fields.
    static func body(fields: [String: String], visitorData: String?, locale: RequestLocale, extra: [String: Any] = [:]) -> Data {
        let client = ClientProfile.tv
        var clientFields: [String: Any] = [
            "clientName": client.clientName, "clientVersion": client.clientVersion, "clientScreen": client.clientScreen,
            "userAgent": client.userAgent,
            "tvAppInfo": ["appQuality": "TV_APP_QUALITY_FULL_ANIMATION", "zylonLeftNav": true],
            "webpSupport": false, "animatedWebpSupport": true,
            "acceptLanguage": locale.language, "acceptRegion": locale.region, "utcOffsetMinutes": String(locale.utcOffsetMinutes),
        ]
        if let visitorData { clientFields["visitorData"] = visitorData }
        var root: [String: Any] = [
            "context": ["client": clientFields, "user": ["enableSafetyMode": false, "lockedSafetyMode": false]],
            "racyCheckOk": true, "contentCheckOk": true,
        ]
        for (key, value) in fields { root[key] = value }
        for (key, value) in extra { root[key] = value }
        return (try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])) ?? Data()
    }

    func logPage(_ what: String, _ page: FeedPage, start: ContinuousClock.Instant, extra: String?) {
        let counts = Dictionary(grouping: page.items, by: \.kind).mapValues(\.count)
        let kinds = FeedItem.Kind.allCases.compactMap { kind in counts[kind].map { "\(kind.rawValue)=\($0)" } }.joined(separator: " ")
        log("browse \(what) items=\(page.items.count) \(kinds) continuation=\(page.continuation == nil ? "n" : "y") "
            + "ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))" + (extra.map { " \($0)" } ?? ""))
    }
}
