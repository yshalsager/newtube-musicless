import Foundation

/// A channel (US-021), from `/browse` with the channel id over the TV client
/// (`tvBrowseRenderer` → `tvSurfaceContentRenderer`): the header, and its shelves as sections
/// (Videos, Live, Playlists, …), each with its own next page, as the Android phone shows them in
/// tabs (MobileChannelActivity).
public struct ChannelPage: Sendable {
    public struct Section: Sendable, Identifiable {
        public var id: Int
        public var title: String
        public var page: FeedPage
        /// The shelf's link to the channel's Videos tab (its params name the `videos` tab).
        public var isUploads: Bool
    }

    public var id: String
    public var title: String
    public var handle: String?
    public var subscribers: String?
    public var avatar: URL?
    public var banner: URL?
    public var sections: [Section]
}

/// A playlist (`/browse` with `VL<id>`): its title, owner and videos.
public struct PlaylistPage: Sendable {
    public var id: String
    public var title: String
    public var owner: String?
    public var page: FeedPage
}

extension FeedParser {
    /// The `videos` tab's browse params begin with this (protobuf field 2, "videos").
    static let uploadsParamsPrefix = "EgZ2aWRlb3M"

    public static func channel(_ data: Data, id: String) throws -> ChannelPage {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw BrowseError("not JSON") }
        let surface = JSONNode(object)["contents"]["tvBrowseRenderer"]["content"]["tvSurfaceContentRenderer"]
        let header = surface["header"]["channelHeaderRenderer"]
        guard surface.exists else { throw BrowseError("no channel surface") }
        let subtitle = (header["subtitle"]["lineRenderer"]["items"].array ?? [])
            .compactMap { $0["lineItemRenderer"]["text"].text }
            .filter { $0.trimmingCharacters(in: .whitespaces) != "•" }
        var sections: [ChannelPage.Section] = []
        for section in surface["content"]["sectionListRenderer"]["contents"].array ?? [] {
            let shelf = section["shelfRenderer"]
            guard shelf.exists else { continue }
            let shelfHeader = shelf["headerRenderer"]["shelfHeaderRenderer"]
            let titleNode = shelfHeader["avatarLockup"]["avatarLockupRenderer"]["title"]
            let title = (titleNode.text ?? shelfHeader["title"].text ?? "").trimmingCharacters(in: .whitespaces)
            let list = shelf["content"]["horizontalListRenderer"].exists ? shelf["content"]["horizontalListRenderer"]
                : shelf["content"]["verticalListRenderer"]
            let items = (list["items"].array ?? []).compactMap(item)
            guard !items.isEmpty else { continue }
            let params = titleNode["runs"][0]["navigationEndpoint"]["browseEndpoint"]["params"].string
                ?? shelf["endpoint"]["browseEndpoint"]["params"].string ?? ""
            sections.append(ChannelPage.Section(id: sections.count, title: title, page: FeedPage(items: items, continuation: continuation(list)),
                                                isUploads: params.hasPrefix(uploadsParamsPrefix)))
        }
        return ChannelPage(id: id, title: header["title"].text ?? "", handle: subtitle.first { $0.hasPrefix("@") },
                           subscribers: subtitle.first { !$0.hasPrefix("@") },
                           avatar: bestThumbnail(header["avatar"]["thumbnails"]),
                           banner: bestThumbnail(header["backgroundImage"]["thumbnails"]), sections: sections)
    }

    public static func playlist(_ data: Data, id: String) throws -> PlaylistPage {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw BrowseError("not JSON") }
        let columns = JSONNode(object)["contents"]["tvBrowseRenderer"]["content"]["tvSurfaceContentRenderer"]["content"]["twoColumnRenderer"]
        let list = columns["rightColumn"]["playlistVideoListRenderer"]
        guard list.exists else { throw BrowseError("no playlist") }
        let metadata = columns["leftColumn"]["entityMetadataRenderer"]
        let owner = (metadata["bylines"].array ?? []).lazy
            .flatMap { $0["lineRenderer"]["items"].array ?? [] }
            .compactMap { $0["lineItemRenderer"]["text"].text }
            .first
        return PlaylistPage(id: id, title: metadata["title"].text ?? "", owner: owner,
                            page: FeedPage(items: (list["contents"].array ?? []).compactMap(item), continuation: continuation(list)))
    }

    /// The next page of any list: `sectionListContinuation` (search, related), or a single list's
    /// (`horizontalListContinuation` of a channel shelf, `playlistVideoListContinuation`, a grid's).
    public static func continuationPage(_ data: Data) throws -> FeedPage {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw BrowseError("not JSON") }
        let contents = JSONNode(object)["continuationContents"]
        if contents["sectionListContinuation"].exists { return sectionList(contents["sectionListContinuation"]) }
        for key in ["horizontalListContinuation", "playlistVideoListContinuation", "gridContinuation", "verticalListContinuation"]
        where contents[key].exists {
            let list = contents[key]
            return FeedPage(items: ((list["items"].array ?? list["contents"].array) ?? []).compactMap(item), continuation: continuation(list))
        }
        throw BrowseError("no continuation contents")
    }
}

extension BrowseClient {
    /// A channel's page (BrowseService2 over the TV client).
    public func channel(id: String) async throws -> ChannelPage {
        let start = ContinuousClock.now
        let page = try FeedParser.channel(try await post("browse", ["browseId": id]), id: id)
        log("browse channel sections=\(page.sections.count) items=\(page.sections.reduce(0) { $0 + $1.page.items.count }) "
            + "uploads=\(page.sections.contains(where: \.isUploads) ? "y" : "n") ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
        return page
    }

    /// A playlist's page (`VL` + its id).
    public func playlist(id: String) async throws -> PlaylistPage {
        let start = ContinuousClock.now
        let page = try FeedParser.playlist(try await post("browse", ["browseId": id.hasPrefix("VL") ? id : "VL" + id]), id: id)
        log("browse playlist items=\(page.page.items.count) continuation=\(page.page.continuation == nil ? "n" : "y") "
            + "ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
        return page
    }

    /// The next page of a channel section or a playlist.
    public func continueBrowse(_ token: String) async throws -> FeedPage {
        let start = ContinuousClock.now
        let page = try FeedParser.continuationPage(try await post("browse", ["continuation": token]))
        log("browse continuation items=\(page.items.count) continuation=\(page.continuation == nil ? "n" : "y") "
            + "ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
        return page
    }
}
