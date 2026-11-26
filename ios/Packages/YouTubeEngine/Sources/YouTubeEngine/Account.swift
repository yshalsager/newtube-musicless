import Foundation

/// The signed-in account as the app shows it (`accounts_list`, AccountInt).
public struct AccountInfo: Codable, Sendable, Equatable {
    public var name: String
    /// The e-mail address or similar (`accountByline`); shown on the account row only.
    public var byline: String?
    public var handle: String?
    public var avatar: URL?
}

extension FeedParser {
    /// AccountsList: `contents[0].accountSectionListRenderer.contents[0].accountItemSectionRenderer
    /// .contents[*].accountItem`; the selected one, else the first.
    public static func account(_ data: Data) throws -> AccountInfo {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw BrowseError("not JSON") }
        let items = (JSONNode(object)["contents"][0]["accountSectionListRenderer"]["contents"][0]["accountItemSectionRenderer"]["contents"]
            .array ?? []).map { $0["accountItem"] }.filter(\.exists)
        guard let item = items.first(where: { $0["isSelected"].value as? Bool == true }) ?? items.first,
              let name = item["accountName"].text else { throw BrowseError("no account") }
        return AccountInfo(name: name, byline: item["accountByline"].text, handle: item["channelHandle"].text,
                           avatar: bestThumbnail(item["accountPhoto"]["thumbnails"]))
    }
}

extension BrowseClient {
    /// The account's name and photo (AuthApiHelper.getAccountsListQuery, with the account).
    public func account() async throws -> AccountInfo {
        let mask: [String: Any] = ["accountReadMask": ["returnOwner": true, "returnBrandAccounts": true, "returnPersonaAccounts": false]]
        return try FeedParser.account(try await post("account/accounts_list", [:], extra: mask, signedIn: true))
    }
}

/// Watch history, signed in (US-022; LANES §3, MediaServiceCore's TrackingService): the stats
/// pings that put a video in the account's history and record how far it was watched. Their
/// `ei`, `vm` and `of` come from an answer asked **with the account** (the account route's, or one
/// TV /player sent for this when the winner was anonymous), and they carry the account.
public struct WatchHistory: Sendable {
    /// From the account-bound answer's `videostatsPlaybackUrl`.
    public struct Tracking: Sendable, Equatable {
        public var eventID: String
        public var visitorMonitoring: String
        public var of: String
        /// The client playback nonce sent with that answer's request.
        public var cpn: String

        public init?(videostatsURL: String?, cpn: String) {
            guard let videostatsURL, let items = URLComponents(string: videostatsURL)?.queryItems,
                  let ei = items.first(where: { $0.name == "ei" })?.value, let vm = items.first(where: { $0.name == "vm" })?.value,
                  let of = items.first(where: { $0.name == "of" })?.value else { return nil }
            eventID = ei
            visitorMonitoring = vm
            self.of = of
            self.cpn = cpn
        }
    }

    static let startThreshold: Double = 3 * 60
    static let renewInterval: TimeInterval = 30 * 60

    /// The last position sent: (video, seconds, when). TrackingService.mPosition.
    private var last: (videoID: String, position: Double, at: Date)?

    public init() {}

    /// The pings for `videoID` at `position` of `length` seconds (TrackingService.updateWatchTime).
    /// Within the last 5 % it's marked as fully watched.
    public mutating func pings(videoID: String, position: Double, length: Double, tracking: Tracking, now: Date = Date()) -> [URL] {
        let known = last?.videoID == videoID
        let oldPosition = known ? last!.position : position < Self.startThreshold ? 0 : position
        defer { last = (videoID, position, now) }
        var urls: [URL] = []
        if length - position < length * 0.05 {
            urls.append(Self.url("playback", [("docid", videoID), ("final", "1")], tracking))
            urls.append(Self.url("watchtime", [("docid", videoID), ("final", "1"), ("len", Self.number(length)),
                                               ("st", Self.number(length)), ("et", Self.number(length)), ("cmt", Self.number(length))], tracking))
            return urls
        }
        let outdated = last.map { now.timeIntervalSince($0.at) > Self.renewInterval } ?? true
        if !known || outdated {
            urls.append(Self.url("playback", [("docid", videoID), ("len", Self.number(length)), ("cmt", Self.number(oldPosition))], tracking))
        }
        urls.append(Self.url("watchtime", [("docid", videoID), ("len", Self.number(length)), ("st", Self.number(oldPosition)),
                                           ("et", Self.number(position)), ("cmt", Self.number(position))], tracking))
        return urls
    }

    static func url(_ kind: String, _ fields: [(String, String)], _ tracking: Tracking) -> URL {
        var components = URLComponents(string: "https://www.youtube.com/api/stats/\(kind)")!
        components.queryItems = [URLQueryItem(name: "ns", value: "yt"), URLQueryItem(name: "ver", value: "2")]
            + fields.map { URLQueryItem(name: $0.0, value: $0.1) }
            + [URLQueryItem(name: "cpn", value: tracking.cpn), URLQueryItem(name: "ei", value: tracking.eventID),
               URLQueryItem(name: "vm", value: tracking.visitorMonitoring), URLQueryItem(name: "of", value: tracking.of)]
        return components.url!
    }

    static func number(_ value: Double) -> String { String(format: "%.3f", value) }
}
