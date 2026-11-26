import Foundation

/// One card of a list: a search result, a feed or channel item (MediaServiceCore's `ItemWrapper`
/// getters over `lockupViewModel`, `tileRenderer` and the classic `*VideoRenderer`s).
public struct FeedItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, CaseIterable {
        case video, live, upcoming, short, channel, playlist
    }

    public var kind: Kind
    /// The video, channel or playlist id.
    public var id: String
    public var title: String
    /// The channel's name (videos), or the handle (channels).
    public var channel: String?
    public var channelID: String?
    public var thumbnail: URL?
    /// The length badge, as YouTube writes it ("10:35"); nil for live, channels and Shorts.
    public var duration: String?
    /// The metadata after the channel: views and age for a video ("23M views", "12 years ago"),
    /// subscribers for a channel, the video count for a playlist. Localized by YouTube.
    public var details: [String]
    /// Quality and status badges ("4K", "CC", "New").
    public var badges: [String]
    /// How much of it the account has watched, 1–100, from YouTube's red bar; nil when none.
    public var percentWatched: Int?

    public init(kind: Kind, id: String, title: String, channel: String? = nil, channelID: String? = nil, thumbnail: URL? = nil,
                duration: String? = nil, details: [String] = [], badges: [String] = []) {
        self.kind = kind
        self.id = id
        self.title = title
        self.channel = channel
        self.channelID = channelID
        self.thumbnail = thumbnail
        self.duration = duration
        self.details = details
        self.badges = badges
    }

    /// Something that plays in the player.
    public var isPlayable: Bool { kind == .video || kind == .live || kind == .upcoming || kind == .short }
}

/// A page of a list and the token for the next one.
public struct FeedPage: Sendable {
    public var items: [FeedItem]
    public var continuation: String?

    public init(items: [FeedItem], continuation: String?) {
        self.items = items
        self.continuation = continuation
    }
}

/// Parses browse-shaped answers. `/search` (SearchResultHelper.getSections, SearchService2):
/// `contents.sectionListRenderer.contents` or, for a continuation,
/// `continuationContents.sectionListContinuation.contents`; each `shelfRenderer` is a section, its
/// items in order, and the first section with a next page is the one that continues (the main
/// results come first, MobileSearchActivity.firstPageableGroup). Other section kinds (the
/// `clusterShelfRenderer` of a channel's videos) are not sections on Android either.
public enum FeedParser {
    public static func page(_ data: Data) throws -> FeedPage {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw BrowseError("not JSON") }
        let root = JSONNode(object)
        let list = root["contents"]["sectionListRenderer"].exists ? root["contents"]["sectionListRenderer"]
            : root["continuationContents"]["sectionListContinuation"]
        guard list["contents"].array != nil else {
            if let alert = root["alerts"][0]["alertRenderer"]["text"].text { throw BrowseError("alert: \(alert)") }
            throw BrowseError("no sections")
        }
        return sectionList(list)
    }

    static func continuation(_ list: JSONNode) -> String? {
        list["continuations"][0]["nextContinuationData"]["continuation"].string
            ?? list["continuations"][0]["reloadContinuationData"]["continuation"].string
    }

    /// One item wrapper; nil for what isn't a card (a continuation item, an unknown renderer).
    public static func item(_ wrapper: JSONNode) -> FeedItem? {
        guard var item = shape(wrapper) else { return nil }
        if item.isPlayable { item.percentWatched = percentWatched(wrapper) }
        return item
    }

    /// The account's watched share of a card, as Android reads it (CommonHelper.kt
    /// `getPercentWatched`): a lockup's progress bar, a tile's or a classic renderer's resume
    /// overlay. Signed out, YouTube sends none.
    static func percentWatched(_ wrapper: JSONNode) -> Int? {
        var values: [Int?] = []
        for overlay in wrapper["lockupViewModel"]["contentImage"]["thumbnailViewModel"]["overlays"].array ?? [] {
            values.append(overlay["thumbnailBottomOverlayViewModel"]["progressBar"]["thumbnailOverlayProgressBarViewModel"]["startPercent"].int)
        }
        var overlays = wrapper["tileRenderer"]["header"]["tileHeaderRenderer"]["thumbnailOverlays"].array ?? []
        for key in ["videoRenderer", "gridVideoRenderer", "compactVideoRenderer"] {
            overlays += wrapper[key]["thumbnailOverlays"].array ?? []
        }
        for overlay in overlays {
            values.append(overlay["thumbnailOverlayResumePlaybackRenderer"]["percentDurationWatched"].int)
        }
        guard let percent = values.compactMap({ $0 }).first, percent > 0 else { return nil }
        return min(percent, 100)
    }

    static func shape(_ wrapper: JSONNode) -> FeedItem? {
        if wrapper["lockupViewModel"].exists { return lockup(wrapper["lockupViewModel"]) }
        if wrapper["shortsLockupViewModel"].exists { return shortsLockup(wrapper["shortsLockupViewModel"]) }
        if wrapper["tileRenderer"].exists { return tile(wrapper["tileRenderer"]) }
        for key in ["videoRenderer", "gridVideoRenderer", "compactVideoRenderer"] where wrapper[key].exists {
            return classicVideo(wrapper[key])
        }
        if wrapper["reelItemRenderer"].exists {
            let reel = wrapper["reelItemRenderer"]
            guard let id = reel["videoId"].string else { return nil }
            return FeedItem(kind: .short, id: id, title: reel["headline"].text ?? "", thumbnail: bestThumbnail(reel["thumbnail"]["thumbnails"]))
        }
        return nil
    }

    // MARK: lockupViewModel (CommonHelper.kt `LockupItem`)

    static func lockup(_ lockup: JSONNode) -> FeedItem? {
        let tap = lockup["rendererContext"]["commandContext"]["onTap"]["innertubeCommand"]
        let contentType = lockup["contentType"].string ?? ""
        let metadata = lockup["metadata"]["lockupMetadataViewModel"]
        let title = metadata["title"]["content"].string ?? metadata["title"].text ?? ""
        let rows = metadata["metadata"]["contentMetadataViewModel"]["metadataRows"].array ?? []
        let parts = rows.map { row in (row["metadataParts"].array ?? []).compactMap { $0["text"]["content"].string } }
        let badges = rows.flatMap { row in (row["badges"].array ?? []).compactMap { $0["badgeViewModel"]["badgeText"].string } }
        let image = lockup["contentImage"]["thumbnailViewModel"].exists ? lockup["contentImage"]["thumbnailViewModel"]
            : lockup["contentImage"]["collectionThumbnailViewModel"]["primaryThumbnail"]["thumbnailViewModel"]
        let thumbnail = bestSource(image["image"]["sources"])
        let overlay = thumbnailBadges(image["overlays"])

        switch contentType {
        case "LOCKUP_CONTENT_TYPE_CHANNEL":
            guard let id = lockup["contentId"].string ?? tap["browseEndpoint"]["browseId"].string else { return nil }
            return FeedItem(kind: .channel, id: id, title: title, channel: parts.first?.first, channelID: id, thumbnail: thumbnail,
                            details: Array(parts.dropFirst().joined()), badges: badges)
        case "LOCKUP_CONTENT_TYPE_PLAYLIST", "LOCKUP_CONTENT_TYPE_ALBUM", "LOCKUP_CONTENT_TYPE_PODCAST":
            guard let id = lockup["contentId"].string ?? tap["watchEndpoint"]["playlistId"].string else { return nil }
            return FeedItem(kind: .playlist, id: id, title: title, channel: parts.first?.first, channelID: menuChannelID(lockup),
                            thumbnail: thumbnail, duration: overlay.text, details: Array(parts.dropFirst().joined()), badges: badges)
        default:
            // A Short says so by its content type or its tap (a reelWatchEndpoint), never its length.
            let isShort = contentType == "LOCKUP_CONTENT_TYPE_SHORT" || tap["reelWatchEndpoint"].exists
            guard let id = lockup["contentId"].string ?? tap["watchEndpoint"]["videoId"].string
                    ?? tap["reelWatchEndpoint"]["videoId"].string else { return nil }
            let kind: FeedItem.Kind = isShort ? .short : overlay.live ? .live : overlay.upcoming ? .upcoming : .video
            return FeedItem(kind: kind, id: id, title: title, channel: parts.first?.first, channelID: menuChannelID(lockup),
                            thumbnail: thumbnail, duration: kind == .video ? overlay.text : nil,
                            details: Array(parts.dropFirst().joined()), badges: badges)
        }
    }

    static func shortsLockup(_ lockup: JSONNode) -> FeedItem? {
        let tap = lockup["onTap"]["innertubeCommand"]
        guard let id = tap["reelWatchEndpoint"]["videoId"].string ?? lockup["entityId"].string?.replacingOccurrences(of: "shorts-shelf-item-", with: "")
        else { return nil }
        return FeedItem(kind: .short, id: id, title: lockup["overlayMetadata"]["primaryText"]["content"].string ?? "",
                        thumbnail: bestSource(lockup["thumbnail"]["sources"]))
    }

    /// The thumbnail's length badge, and whether it marks a live or upcoming video. Two shapes:
    /// `thumbnailBottomOverlayViewModel.badges` (2026 answers) and
    /// `thumbnailOverlayBadgeViewModel.thumbnailBadges` (what CommonHelper.kt reads).
    static func thumbnailBadges(_ overlays: JSONNode) -> (text: String?, live: Bool, upcoming: Bool) {
        for overlay in overlays.array ?? [] {
            let badges = overlay["thumbnailBottomOverlayViewModel"]["badges"].array
                ?? overlay["thumbnailOverlayBadgeViewModel"]["thumbnailBadges"].array ?? []
            for badge in badges {
                let model = badge["thumbnailBadgeViewModel"]
                let style = model["badgeStyle"].string ?? ""
                let text = model["text"].string
                if style.hasSuffix("_LIVE") { return (text, true, false) }
                if style.hasSuffix("_UPCOMING") { return (text, false, true) }
                if let text, !text.isEmpty { return (text, false, false) }
            }
        }
        return (nil, false, false)
    }

    /// A video lockup's channel: the "Go to channel" item of its long-press menu (getBrowseId).
    static func menuChannelID(_ lockup: JSONNode) -> String? {
        let items = lockup["rendererContext"]["commandContext"]["onLongPress"]["innertubeCommand"]["showMenuCommand"]["menu"]["menuRenderer"]["items"]
        for item in items.array ?? [] {
            if let id = item["menuNavigationItemRenderer"]["navigationEndpoint"]["browseEndpoint"]["browseId"].string, id.hasPrefix("UC") {
                return id
            }
        }
        return nil
    }

    // MARK: tileRenderer (the TV answers' classic card)

    static func tile(_ tile: JSONNode) -> FeedItem? {
        let endpoint = tile["onSelectCommand"]
        let header = tile["header"]["tileHeaderRenderer"]
        let metadata = tile["metadata"]["tileMetadataRenderer"]
        let title = metadata["title"].text ?? ""
        let lines = (metadata["lines"].array ?? []).map { line in
            (line["lineRenderer"]["items"].array ?? []).compactMap { $0["lineItemRenderer"]["text"].text }
                .filter { $0.trimmingCharacters(in: .whitespaces) != "•" }
        }
        let badges = (metadata["lines"].array ?? []).flatMap { line in
            (line["lineRenderer"]["items"].array ?? []).compactMap { $0["lineItemRenderer"]["badge"]["metadataBadgeRenderer"]["label"].string }
        }
        let thumbnail = bestThumbnail(header["thumbnail"]["thumbnails"])
        var duration: String?, live = false, upcoming = false
        for overlay in header["thumbnailOverlays"].array ?? [] {
            let status = overlay["thumbnailOverlayTimeStatusRenderer"]
            guard status.exists else { continue }
            let style = status["style"].string ?? ""
            live = style == "LIVE"
            upcoming = style == "UPCOMING"
            if style == "SHORTS" { return endpoint["watchEndpoint"]["videoId"].string.map { FeedItem(kind: .short, id: $0, title: title) } }
            if !live, !upcoming { duration = status["text"].text }
        }
        switch tile["contentType"].string ?? "" {
        case "TILE_CONTENT_TYPE_SHORTS":
            guard let id = endpoint["reelWatchEndpoint"]["videoId"].string ?? endpoint["watchEndpoint"]["videoId"].string
                    ?? tile["contentId"].string else { return nil }
            return FeedItem(kind: .short, id: id, title: title, thumbnail: thumbnail)
        case "TILE_CONTENT_TYPE_CHANNEL":
            guard let id = endpoint["browseEndpoint"]["browseId"].string else { return nil }
            return FeedItem(kind: .channel, id: id, title: title, channelID: id, thumbnail: thumbnail, details: lines.flatMap { $0 })
        case "TILE_CONTENT_TYPE_PLAYLIST":
            guard let id = endpoint["watchEndpoint"]["playlistId"].string ?? endpoint["browseEndpoint"]["browseId"].string else { return nil }
            return FeedItem(kind: .playlist, id: id, title: title, channel: lines.first?.first, thumbnail: thumbnail,
                            details: lines.dropFirst().flatMap { $0 })
        default:
            if endpoint["reelWatchEndpoint"].exists, let id = endpoint["reelWatchEndpoint"]["videoId"].string {
                return FeedItem(kind: .short, id: id, title: title, thumbnail: thumbnail)
            }
            guard let id = endpoint["watchEndpoint"]["videoId"].string else { return nil }
            return FeedItem(kind: live ? .live : upcoming ? .upcoming : .video, id: id, title: title, channel: lines.first?.first,
                            channelID: tileChannelID(tile), thumbnail: thumbnail, duration: duration,
                            details: lines.dropFirst().flatMap { $0 }, badges: badges)
        }
    }

    static func tileChannelID(_ tile: JSONNode) -> String? {
        let items = tile["menu"]["menuRenderer"]["items"]
        for item in items.array ?? [] {
            if let id = item["menuNavigationItemRenderer"]["navigationEndpoint"]["browseEndpoint"]["browseId"].string, id.hasPrefix("UC") {
                return id
            }
        }
        return nil
    }

    // MARK: classic renderers (web-shaped answers)

    static func classicVideo(_ video: JSONNode) -> FeedItem? {
        guard let id = video["videoId"].string else { return nil }
        let owner = video["ownerText"].exists ? video["ownerText"] : video["shortBylineText"]
        var details: [String] = []
        if let views = video["shortViewCountText"].text ?? video["viewCountText"].text { details.append(views) }
        if let age = video["publishedTimeText"].text { details.append(age) }
        let live = (video["badges"].array ?? []).contains { $0["metadataBadgeRenderer"]["style"].string == "BADGE_STYLE_TYPE_LIVE_NOW" }
        return FeedItem(kind: live ? .live : .video, id: id, title: video["title"].text ?? "", channel: owner.text,
                        channelID: owner["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string,
                        thumbnail: bestThumbnail(video["thumbnail"]["thumbnails"]), duration: video["lengthText"].text, details: details)
    }

    // MARK: thumbnails

    /// The widest of `[{url, width, height}]`; protocol-relative URLs get https.
    static func bestSource(_ sources: JSONNode) -> URL? {
        let best = (sources.array ?? []).max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }
        return best?["url"].string.flatMap(absoluteURL)
    }

    static func bestThumbnail(_ thumbnails: JSONNode) -> URL? { bestSource(thumbnails) }

    static func absoluteURL(_ string: String) -> URL? {
        URL(string: string.hasPrefix("//") ? "https:" + string : string)
    }
}

/// A read-only walk over `JSONSerialization` output: missing keys and wrong types give an empty
/// node, so a path reads like the Kotlin `?.` chains it ports.
public struct JSONNode {
    let value: Any?

    public init(_ value: Any?) { self.value = value }

    public subscript(key: String) -> JSONNode { JSONNode((value as? [String: Any])?[key]) }
    public subscript(index: Int) -> JSONNode {
        guard let array = value as? [Any], array.indices.contains(index) else { return JSONNode(nil) }
        return JSONNode(array[index])
    }

    public var exists: Bool { value != nil && !(value is NSNull) }
    public var string: String? { value as? String }
    public var int: Int? { (value as? NSNumber)?.intValue ?? (value as? String).flatMap { Int($0) } }
    public var array: [JSONNode]? { (value as? [Any])?.map(JSONNode.init) }

    /// A text field in any of its shapes: `simpleText`, `runs`, `content`, or a plain string.
    public var text: String? {
        if let string { return string }
        if let simple = self["simpleText"].string { return simple }
        if let content = self["content"].string { return content }
        if let runs = self["runs"].array {
            let joined = runs.compactMap { $0["text"].string }.joined()
            return joined.isEmpty ? nil : joined
        }
        return nil
    }
}
