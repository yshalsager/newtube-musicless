import Foundation
import Testing
@testable import YouTubeEngine

/// US-023: the signed-in feeds. A Subscriptions answer can't be recorded without an account, so
/// these build one in BrowseHelper.kt's shape from recorded tiles.
@Suite struct FeedsTests {
    /// Tiles from the recorded channel answer.
    static func tiles(_ count: Int) throws -> [Any] {
        let data = try BrowseParserTests.fixture("channel_blender")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let sections = JSONNode(root)["contents"]["tvBrowseRenderer"]["content"]["tvSurfaceContentRenderer"]["content"]["sectionListRenderer"]["contents"]
        let items = try #require(sections[1]["shelfRenderer"]["content"]["horizontalListRenderer"]["items"].value as? [Any])
        return Array(items.prefix(count))
    }

    static func answer(_ contents: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["contents": ["tvBrowseRenderer": ["content": contents]]])
    }

    @Test func subscriptionsReadTheAllTabsGrid() throws {
        let grid: [String: Any] = ["gridRenderer": ["items": try Self.tiles(4),
                                                    "continuations": [["nextContinuationData": ["continuation": "NEXT"]]]]]
        let channelTab: [String: Any] = ["tabRenderer": ["title": "A channel", "endpoint": ["browseEndpoint": ["browseId": "UCxyz"]],
                                                         "content": ["tvSurfaceContentRenderer": ["content": ["gridRenderer": ["items": try Self.tiles(1)]]]]]]
        let allTab: [String: Any] = ["tabRenderer": ["title": "All", "endpoint": ["browseEndpoint": ["browseId": "FEsubscriptions"]],
                                                     "content": ["tvSurfaceContentRenderer": ["content": grid]]]]
        let data = try Self.answer(["tvSecondaryNavRenderer": ["sections": [["tvSecondaryNavSectionRenderer": ["tabs": [channelTab, allTab]]]]]])
        let page = try FeedParser.feed(data)
        #expect(page.items.count == 4 && page.continuation == "NEXT", "the FEsubscriptions tab, not the first one")
    }

    @Test func homeReadsShelvesAndRowsAndSignedOutIsEmpty() throws {
        let shelves: [String: Any] = ["sectionListRenderer": ["contents": [
            ["shelfRenderer": ["content": ["horizontalListRenderer": ["items": try Self.tiles(3),
                                                                      "continuations": [["nextContinuationData": ["continuation": "SHELF"]]]]]]],
            ["itemSectionRenderer": ["contents": try Self.tiles(2)]],
        ]]]
        let page = try FeedParser.feed(try Self.answer(["tvSurfaceContentRenderer": ["content": shelves]]))
        #expect(page.items.count == 5 && page.continuation == "SHELF")
        let signedOut = try FeedParser.feed(try BrowseParserTests.fixture("home_signed_out"))
        #expect(signedOut.items.isEmpty && signedOut.continuation == nil)
    }

    // MARK: The red bar (percentWatched), signed in

    /// A recorded tile with a resume overlay added, as signed-in answers carry it.
    static func tile(percent: Int?) throws -> [String: Any] {
        var wrapper = try #require(try Self.tiles(1).first as? [String: Any])
        var tile = try #require(wrapper["tileRenderer"] as? [String: Any])
        var header = try #require(tile["header"] as? [String: Any])
        var renderer = try #require(header["tileHeaderRenderer"] as? [String: Any])
        var overlays = renderer["thumbnailOverlays"] as? [Any] ?? []
        if let percent { overlays.append(["thumbnailOverlayResumePlaybackRenderer": ["percentDurationWatched": percent]]) }
        renderer["thumbnailOverlays"] = overlays
        header["tileHeaderRenderer"] = renderer
        tile["header"] = header
        wrapper["tileRenderer"] = tile
        return wrapper
    }

    @Test func tilesCarryTheWatchedShare() throws {
        #expect(FeedParser.item(JSONNode(try Self.tile(percent: 42)))?.percentWatched == 42)
        #expect(FeedParser.item(JSONNode(try Self.tile(percent: nil)))?.percentWatched == nil, "signed out: no bar")
        #expect(FeedParser.item(JSONNode(try Self.tile(percent: 0)))?.percentWatched == nil, "0 % draws nothing")
        #expect(FeedParser.item(JSONNode(try Self.tile(percent: 130)))?.percentWatched == 100)
    }

    @Test func lockupsAndClassicRenderersCarryItToo() throws {
        let lockup: [String: Any] = ["lockupViewModel": [
            "contentId": "abc", "contentType": "LOCKUP_CONTENT_TYPE_VIDEO",
            "contentImage": ["thumbnailViewModel": ["overlays": [
                ["thumbnailBottomOverlayViewModel": ["progressBar": ["thumbnailOverlayProgressBarViewModel": ["startPercent": 64]]]],
            ]]],
            "metadata": ["lockupMetadataViewModel": ["title": ["content": "A video"]]],
        ]]
        #expect(FeedParser.item(JSONNode(lockup))?.percentWatched == 64)
        let classic: [String: Any] = ["videoRenderer": [
            "videoId": "def", "title": ["simpleText": "A video"],
            "thumbnailOverlays": [["thumbnailOverlayResumePlaybackRenderer": ["percentDurationWatched": 7]]],
        ]]
        #expect(FeedParser.item(JSONNode(classic))?.percentWatched == 7)
    }

    @Test func historyIsATVFeed() {
        #expect(Feed.history.rawValue == "FEhistory")
    }
}
