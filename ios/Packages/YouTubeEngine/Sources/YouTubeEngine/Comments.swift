import Foundation

/// A comment (US-026, read-only; CommentsHelper.kt over the TV client's `commentRenderer`).
public struct Comment: Sendable, Identifiable, Equatable {
    public var id: String
    public var author: String
    public var avatar: URL?
    public var text: String
    public var published: String?
    public var likes: String?
    public var replyCount: Int
    /// The token for its replies (`detailViewEndpoint`), when it has any.
    public var repliesToken: String?
    public var pinned: String?
}

public struct CommentsPage: Sendable {
    public var comments: [Comment]
    public var continuation: String?
}

extension FeedParser {
    /// A comments page: `continuationContents.itemSectionContinuation` of `commentThreadRenderer`s
    /// (or bare `commentRenderer`s). A replies page starts with the parent: `parentID` drops it.
    public static func comments(_ data: Data, parentID: String? = nil) throws -> CommentsPage {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw BrowseError("not JSON") }
        let section = JSONNode(object)["continuationContents"]["itemSectionContinuation"]
        guard section.exists else { throw BrowseError("no comments section") }
        let comments = (section["contents"].array ?? []).compactMap { wrapper -> Comment? in
            let renderer = wrapper["commentThreadRenderer"]["comment"]["commentRenderer"].exists
                ? wrapper["commentThreadRenderer"]["comment"]["commentRenderer"] : wrapper["commentRenderer"]
            return comment(renderer)
        }
        .filter { $0.id != parentID }
        return CommentsPage(comments: comments, continuation: continuation(section))
    }

    static func comment(_ renderer: JSONNode) -> Comment? {
        guard let id = renderer["commentId"].string else { return nil }
        let panel = renderer["detailViewEndpoint"]["showEngagementPanelEndpoint"]["engagementPanel"]["engagementPanelSectionListRenderer"]
        let replies = panel["content"]["sectionListRenderer"]["contents"][0]["itemSectionRenderer"]["continuations"][0]
        return Comment(id: id, author: renderer["authorText"].text ?? "", avatar: bestThumbnail(renderer["authorThumbnail"]["thumbnails"]),
                       text: renderer["contentText"].text ?? "", published: renderer["publishedTimeText"].text,
                       likes: renderer["voteCount"].text, replyCount: renderer["replyCount"].int ?? 0,
                       repliesToken: replies["reloadContinuationData"]["continuation"].string
                           ?? replies["nextContinuationData"]["continuation"].string,
                       pinned: renderer["pinnedCommentBadge"]["pinnedCommentBadgeRenderer"]["label"].text)
    }
}

extension BrowseClient {
    /// A page of comments, or of a comment's replies (CommentsApiParams.getCommentsQuery: the TV
    /// body with the token, on `/next`).
    public func comments(_ token: String, parentID: String? = nil) async throws -> CommentsPage {
        let start = ContinuousClock.now
        let page = try FeedParser.comments(try await post("next", ["continuation": token]), parentID: parentID)
        log("browse comments \(parentID == nil ? "top" : "replies") count=\(page.comments.count) "
            + "continuation=\(page.continuation == nil ? "n" : "y") ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
        return page
    }
}
