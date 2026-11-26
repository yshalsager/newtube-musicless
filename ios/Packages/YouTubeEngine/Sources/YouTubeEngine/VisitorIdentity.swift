import Foundation

/// The anonymous identity every client except WEB_EMBED sends (PRD §4.4), and the TV player JS's
/// signature timestamp. A port of MediaServiceCore's `AppServiceInt` / `AppServiceIntCached`.
public struct VisitorState: Codable, Sendable, Equatable {
    /// `context.client.visitorData` and `X-Goog-Visitor-Id`.
    public var visitorData: String
    /// The TV player JS (`https://www.youtube.com/s/player/<id>/tv-player-ias.vflset/…`).
    public var playerURL: String?
    /// The cookie jar to replay: `VISITOR_INFO1_LIVE` keeps the same visitor id across refreshes.
    public var cookie: String?
    public var fetchedAt: Date
    /// Signature timestamps by player URL.
    public var signatureTimestamps: [String: Int] = [:]

    /// Logs never carry a whole visitor id (FR-21): the first 10 characters, as Android does.
    public var shortVisitor: String { String(visitorData.prefix(10)) }
}

public struct VisitorError: Error, CustomStringConvertible {
    public let description: String
}

public actor VisitorIdentity {
    /// AppServiceIntCached's refresh period.
    public static let lifetime: TimeInterval = 10 * 3600
    /// DefaultHeaders.USER_AGENT_FIRE_TV (USER_AGENT_TV), which youtube.com/tv answers with the TV app.
    public static let fireTVUserAgent = "Mozilla/5.0 (Linux armeabi-v7a; Android 7.1.2; Fire OS 6.0) "
        + "Cobalt/22.lts.3.306369-gold (unlike Gecko) v8/8.8.278.8-jit gles Starboard/13, "
        + "Amazon_ATV_mediatek8695_2019/NS6294 (Amazon, AFTMM, Wireless) com.amazon.firetv.youtube/22.3.r2.v66.0"
    /// AppConstants.CONSENT_ACCEPTED_COOKIE: without it, EU answers expire VISITOR_INFO1_LIVE.
    public static let consentCookie = "SOCS=CAISEwgDEgk5NTA1MzE4OTQaAmVuIAEaBgiA7frSBg"
    static let tvURL = URL(string: "https://www.youtube.com/tv")!

    private let transport: InnerTubeTransport
    private let storeURL: URL?
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var state: VisitorState?
    private var refresh: Task<VisitorState, Error>?
    private var timestampFetches: [String: Task<Int?, Never>] = [:]

    /// - Parameter storeURL: where the state persists (Application Support in the app); nil keeps it in memory.
    public init(transport: InnerTubeTransport, storeURL: URL?, now: @escaping @Sendable () -> Date = { Date() },
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transport = transport
        self.storeURL = storeURL
        self.now = now
        self.log = log
        if let storeURL, let data = try? Data(contentsOf: storeURL) {
            state = try? JSONDecoder().decode(VisitorState.self, from: data)
        }
    }

    /// The visitor, fetched again once it is 10 h old (concurrent callers share one fetch).
    public func current() async throws -> VisitorState {
        if let state, now().timeIntervalSince(state.fetchedAt) < Self.lifetime { return state }
        if let refresh { return try await refresh.value }
        let task = Task { try await self.fetch() }
        refresh = task
        defer { refresh = nil }
        let fresh = try await task.value
        return fresh
    }

    /// A fresh visitor (the one-minute wall's re-roll, US-017): youtube.com/tv asked without the
    /// stored identity cookie, so it hands out a new one. On failure the old visitor stays.
    public func reroll() async throws -> VisitorState {
        let previous = state
        state = nil
        refresh = nil
        do {
            let fresh = try await current()
            log("playback-identity rerolled from=\(previous?.shortVisitor ?? "none") to=\(fresh.shortVisitor)")
            return fresh
        } catch {
            state = previous
            throw error
        }
    }

    /// The player JS's `signatureTimestamp`, fetched once per player URL; -1 when unknown, which
    /// QueryBuilder sends as is.
    public func signatureTimestamp() async -> Int {
        guard let visitor = try? await current(), let playerURL = visitor.playerURL else { return -1 }
        if let known = state?.signatureTimestamps[playerURL] { return known }
        let task = timestampFetches[playerURL] ?? Task { await self.fetchTimestamp(playerURL) }
        timestampFetches[playerURL] = task
        let value = await task.value
        timestampFetches[playerURL] = nil
        if let value, var state, state.playerURL == playerURL {
            state.signatureTimestamps[playerURL] = value
            self.state = state
            persist()
        }
        return value ?? -1
    }

    // MARK: Fetching

    private func fetch() async throws -> VisitorState {
        var request = URLRequest(url: Self.tvURL, timeoutInterval: 20)
        request.setValue(Self.fireTVUserAgent, forHTTPHeaderField: "User-Agent")
        var cookie = state?.cookie
        if cookie?.contains("SOCS=") != true {
            cookie = [cookie, Self.consentCookie].compactMap { $0 }.joined(separator: "; ")
        }
        request.setValue(cookie, forHTTPHeaderField: "Cookie")

        let answer = try await transport.send(request, label: "tv")
        let received = Self.cookies(from: answer.response)
        let page = String(decoding: answer.data, as: UTF8.self)
        guard answer.status == 200, let visitorData = Self.match(#""visitorData":"(.*?)""#, in: page) else {
            throw VisitorError(description: "youtube.com/tv gave no visitorData (HTTP \(answer.status))")
        }
        let playerURL = Self.match(#""player_url":"(.*?)""#, in: page).map(Self.tidyURL)
        var fresh = VisitorState(visitorData: visitorData, playerURL: playerURL,
                                 cookie: Self.nextVisitorCookie(stored: state?.cookie, received: received),
                                 fetchedAt: now())
        if let playerURL, let known = state?.signatureTimestamps[playerURL] {
            fresh.signatureTimestamps[playerURL] = known
        }
        let reused = state.map { Self.visitorID(in: $0.cookie) == Self.visitorID(in: fresh.cookie) } ?? false
        log("visitor fetched visitor=\(fresh.shortVisitor) player=\(playerURL.map(Self.playerID) ?? "none") "
            + "cookie=\(Self.visitorID(in: fresh.cookie) != nil ? "y" : "n") sameId=\(reused ? "y" : "n")")
        state = fresh
        persist()
        return fresh
    }

    private func fetchTimestamp(_ playerURL: String) async -> Int? {
        guard let url = URL(string: playerURL) else { return nil }
        do {
            let answer = try await transport.send(URLRequest(url: url, timeoutInterval: 20), label: "player-js")
            let script = String(decoding: answer.data, as: UTF8.self)
            let value = Self.signatureTimestamp(in: script)
            log("player-js sts=\(value.map(String.init) ?? "none") player=\(Self.playerID(playerURL)) bytes=\(answer.data.count)")
            return value
        } catch {
            return nil
        }
    }

    private func persist() {
        guard let storeURL, let state, let data = try? JSONEncoder().encode(state) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }

    // MARK: Parsing (static, tested)

    /// CommonExtractor's `signatureTimestamp:(\d+)`, also accepting `=`.
    static func signatureTimestamp(in script: String) -> Int? {
        match(#"signatureTimestamp[:=](\d+)"#, in: script).flatMap { Int($0) }
    }

    /// AppServiceInt.nextVisitorCookie: every cookie the answer sends replaces the stored set, but
    /// the stored `VISITOR_INFO1_LIVE` is carried over when the answer didn't issue one (an error
    /// page or a captive portal must not erase the identity). A different id from the server wins.
    static func nextVisitorCookie(stored: String?, received: String?) -> String? {
        guard let storedVisitor = visitorPair(in: stored), visitorPair(in: received) == nil else { return received }
        var merged = ""
        for pair in (received ?? "").split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, !trimmed.hasPrefix("VISITOR_INFO1_LIVE=") { merged += trimmed + "; " }
        }
        return merged + storedVisitor
    }

    /// `ServiceHelper.tidyUrl`: unescape, and make a path absolute on www.youtube.com.
    static func tidyURL(_ raw: String) -> String {
        let url = raw.replacingOccurrences(of: "\\/", with: "/").replacingOccurrences(of: "\\u0026", with: "&")
        return url.hasPrefix("/") ? "https://www.youtube.com" + url : url
    }

    static func playerID(_ url: String) -> String {
        let parts = url.split(separator: "/")
        if let index = parts.firstIndex(of: "player"), index + 1 < parts.count { return String(parts[index + 1]) }
        return "?"
    }

    private static func visitorPair(in cookies: String?) -> String? {
        guard let cookies else { return nil }
        for pair in cookies.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("VISITOR_INFO1_LIVE="), trimmed.count > "VISITOR_INFO1_LIVE=".count { return trimmed }
        }
        return nil
    }

    private static func visitorID(in cookies: String?) -> String? {
        visitorPair(in: cookies).map { String($0.dropFirst("VISITOR_INFO1_LIVE=".count)) }
    }

    /// `name=value; …` of every Set-Cookie (RetrofitHelper.getCookies).
    static func cookies(from response: HTTPURLResponse) -> String? {
        var fields: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { fields[key] = value }
        }
        let url = response.url ?? tvURL
        let pairs = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url).map { "\($0.name)=\($0.value)" }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    static func match(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              found.numberOfRanges > 1, let range = Range(found.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}
