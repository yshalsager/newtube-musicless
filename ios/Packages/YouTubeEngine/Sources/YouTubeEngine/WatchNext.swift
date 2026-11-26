import Foundation

/// What the watch page shows under the player (US-020), from `/next` over the TV client
/// (WatchNextService.getMetadata, MediaItemMetadataImpl): the title, channel, views and date, the
/// description, and the related videos.
public struct WatchNext: Sendable {
    public var videoID: String
    public var title: String
    public var channel: String?
    public var channelID: String?
    public var channelAvatar: URL?
    public var subscribers: String?
    /// The full count ("23,592,420 views") and the short one ("23M views").
    public var views: String?
    public var shortViews: String?
    /// "Published on Nov 10, 2014" and the relative date ("12y ago").
    public var published: String?
    public var age: String?
    public var likes: String?
    public var description: String?
    /// The related videos (the TV client's `pivot`), and the token for more.
    public var related: FeedPage
    /// The comments panel's first-page token and count (US-026).
    public var commentsToken: String?
    public var commentCount: String?

    public init(videoID: String, title: String, related: FeedPage = FeedPage(items: [], continuation: nil)) {
        self.videoID = videoID
        self.title = title
        self.related = related
    }
}

extension FeedParser {
    /// A `/next` answer (WatchNextHelper.kt, MediaItemMetadataImpl.kt).
    public static func watchNext(_ data: Data, videoID: String) throws -> WatchNext {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw BrowseError("not JSON") }
        let root = JSONNode(object)
        let results = root["contents"]["singleColumnWatchNextResults"]
        guard results.exists else { throw BrowseError("no watch-next results") }
        var next = WatchNext(videoID: videoID, title: "")

        // videoMetadataRenderer: the first section's first item that has one.
        var metadata = JSONNode(nil)
        for section in results["results"]["results"]["contents"].array ?? [] {
            for item in section["itemSectionRenderer"]["contents"].array ?? [] where item["videoMetadataRenderer"].exists {
                metadata = item["videoMetadataRenderer"]
                break
            }
            if metadata.exists { break }
        }
        let owner = metadata["owner"]["videoOwnerRenderer"]
        next.title = metadata["title"].text ?? ""
        next.channel = owner["title"].text
        next.channelID = owner["navigationEndpoint"]["browseEndpoint"]["browseId"].string
        next.channelAvatar = bestThumbnail(owner["thumbnail"]["thumbnails"])
        next.subscribers = owner["subscriberCountText"].text
        let counts = metadata["viewCount"]["videoViewCountRenderer"]
        next.views = counts["viewCount"].text
        next.shortViews = counts["shortViewCount"].text
        next.published = metadata["publishedTimeText"].text
        next.age = metadata["dateText"].text

        // The engagement panels: the description (structuredDescriptionContentRenderer) and the
        // comments (`comment-item-section`).
        for panel in root["engagementPanels"].array ?? [] {
            let section = panel["engagementPanelSectionListRenderer"]
            switch section["panelIdentifier"].string {
            case "video-description-ep-identifier":
                for item in section["content"]["structuredDescriptionContentRenderer"]["items"].array ?? [] {
                    let header = item["videoDescriptionHeaderRenderer"]
                    if header.exists {
                        if next.title.isEmpty { next.title = header["title"].text ?? "" }
                        next.channel = next.channel ?? header["channel"].text
                        next.views = next.views ?? header["views"].text
                        next.published = next.published ?? header["publishDate"].text
                        next.likes = header["factoid"][0]["factoidRenderer"]["value"].text
                    }
                    if let body = item["expandableVideoDescriptionBodyRenderer"]["descriptionBodyText"].text {
                        next.description = body
                    }
                }
            case "comment-item-section":
                let header = section["header"]["engagementPanelTitleHeaderRenderer"]
                next.commentCount = header["contextualInfo"].text
                next.commentsToken = header["menu"]["sortFilterSubMenuRenderer"]["subMenuItems"][0]["continuation"]["reloadContinuationData"]["continuation"].string
                    ?? firstContinuation(section["content"]["sectionListRenderer"]["contents"])
            default:
                break
            }
        }

        next.related = sectionList(results["pivot"]["sectionListRenderer"])
        next.related.items.removeAll { $0.id == videoID }
        guard !next.title.isEmpty || !next.related.items.isEmpty else { throw BrowseError("empty watch-next answer") }
        return next
    }

    /// The shelves of a `sectionListRenderer` as one page: their items in order, continued by the
    /// first shelf that has a next page, else by the list's own continuation (the related pivot).
    static func sectionList(_ list: JSONNode) -> FeedPage {
        var items: [FeedItem] = []
        var continuation: String?
        for section in list["contents"].array ?? [] {
            // Shelf.getItems: a shelf's list (horizontal, vertical or a grid), a bare grid, or an
            // item section (the Subscriptions page's rows of 3).
            let shelf = section["shelfRenderer"]
            let content: JSONNode
            if shelf.exists {
                content = shelf["content"]["horizontalListRenderer"].exists ? shelf["content"]["horizontalListRenderer"]
                    : shelf["content"]["verticalListRenderer"].exists ? shelf["content"]["verticalListRenderer"]
                    : shelf["content"]["gridRenderer"]
            } else if section["gridRenderer"].exists {
                content = section["gridRenderer"]
            } else if section["itemSectionRenderer"].exists {
                content = section["itemSectionRenderer"]
            } else {
                continue  // searchBarRenderer, promoShelfRenderer, …
            }
            items += ((content["items"].array ?? content["contents"].array) ?? []).compactMap(item)
            if continuation == nil { continuation = Self.continuation(content) }
        }
        return FeedPage(items: items, continuation: continuation ?? Self.continuation(list))
    }

    static func firstContinuation(_ sections: JSONNode) -> String? {
        for section in sections.array ?? [] {
            if let token = section["itemSectionRenderer"]["continuations"][0]["nextContinuationData"]["continuation"].string {
                return token
            }
        }
        return nil
    }
}
