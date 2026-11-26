import Foundation

/// The signed-in feeds (US-023), over the TV client with the account (BrowseApiHelper):
/// Subscriptions (`FEsubscriptions`), Home (`default`) and History (`FEhistory`, BrowseService2
/// `getHistory`, a TV grid).
public enum Feed: String, Sendable {
    case subscriptions = "FEsubscriptions"
    case home = "default"
    case history = "FEhistory"
}

extension FeedParser {
    /// A TV feed answer (BrowseHelper.kt `BrowseResultTV`):
    /// - Subscriptions is a `tvSecondaryNavRenderer` whose tabs are "All" and one per channel; the
    ///   feed is the tab that browses `FEsubscriptions`, else the first (`getSubscriptionsTab`);
    /// - Home is a `tvSurfaceContentRenderer` of shelves.
    /// Either surface holds a `gridRenderer` or a `sectionListRenderer`. Signed out, Home is only a
    /// search bar: an empty page.
    public static func feed(_ data: Data) throws -> FeedPage {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw BrowseError("not JSON") }
        let content = JSONNode(object)["contents"]["tvBrowseRenderer"]["content"]
        guard content.exists else { throw BrowseError("no TV browse content") }
        var surface = content["tvSurfaceContentRenderer"]["content"]
        let tabs = (content["tvSecondaryNavRenderer"]["sections"][0]["tvSecondaryNavSectionRenderer"]["tabs"].array ?? [])
            .map { $0["tabRenderer"].exists ? $0["tabRenderer"] : $0["expandableTabRenderer"] }
            .filter(\.exists)
        if !tabs.isEmpty {
            let tab = tabs.first { $0["endpoint"]["browseEndpoint"]["browseId"].string == Feed.subscriptions.rawValue } ?? tabs[0]
            surface = tab["content"]["tvSurfaceContentRenderer"]["content"]
        }
        if surface["gridRenderer"].exists {
            let grid = surface["gridRenderer"]
            return FeedPage(items: (grid["items"].array ?? []).compactMap(item), continuation: continuation(grid))
        }
        return sectionList(surface["sectionListRenderer"])
    }
}

extension BrowseClient {
    /// A signed-in feed's first page (throws signed out).
    public func feed(_ feed: Feed) async throws -> FeedPage {
        let start = ContinuousClock.now
        let page = try FeedParser.feed(try await post("browse", ["browseId": feed.rawValue], signedIn: true))
        logPage("feed-\(feed.logName)", page, start: start, extra: nil)
        return page
    }
}

extension Feed {
    var logName: String {
        switch self {
        case .subscriptions: "subscriptions"
        case .home: "home"
        case .history: "history"
        }
    }
}

/// Watch later (`WL`), signed in: PlaylistApiHelper's `edit_playlist` over the TV client.
extension BrowseClient {
    public static let watchLater = "WL"

    /// Adds `videoID` to Watch later, or removes it. Throws signed out or when YouTube says no.
    public func setWatchLater(_ videoID: String, saved: Bool) async throws {
        let action: [String: Any] = saved ? ["addedVideoId": videoID, "action": "ACTION_ADD_VIDEO"]
                                          : ["removedVideoId": videoID, "action": "ACTION_REMOVE_VIDEO_BY_VIDEO_ID"]
        let data = try await post("browse/edit_playlist", ["playlistId": Self.watchLater], extra: ["actions": [action]], signedIn: true)
        let status = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["status"] as? String
        log("watch-later video=\(videoID) saved=\(saved ? "y" : "n") status=\(status ?? "none")")
        guard status == "STATUS_SUCCEEDED" else { throw BrowseError("watch later: \(status ?? "no status")") }
    }
}
