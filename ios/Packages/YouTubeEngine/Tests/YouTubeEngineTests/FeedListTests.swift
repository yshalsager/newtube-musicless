import Testing
@testable import YouTubeEngine

/// US-019: the phone's list rules (ShortsFilter, hoistChannels, FilteredPageTopUp).
@Suite struct FeedListTests {
    static func video(_ id: String) -> FeedItem { FeedItem(kind: .video, id: id, title: id) }
    static func short(_ id: String) -> FeedItem { FeedItem(kind: .short, id: id, title: id) }
    static func channel(_ id: String) -> FeedItem { FeedItem(kind: .channel, id: id, title: id) }

    @Test func shortsAreDroppedAndChannelsOfTheFirstPageGoFirst() {
        var list = FeedList()
        let kept = list.append(FeedPage(items: [Self.video("a"), Self.short("s1"), Self.channel("UC1"), Self.video("b"), Self.short("s2")],
                                        continuation: "next"))
        #expect(kept == 3 && list.droppedShorts == 2)
        #expect(list.items.map(\.id) == ["UC1", "a", "b"])
        // A later page's channel stays where it is; a repeated item isn't added twice.
        list.append(FeedPage(items: [Self.video("b"), Self.channel("UC2"), Self.video("c")], continuation: nil))
        #expect(list.items.map(\.id) == ["UC1", "a", "b", "UC2", "c"])
        #expect(!list.hasMore)
    }

    @Test func onlyChannelsWithinTheFirstTenAreHoisted() {
        var list = FeedList()
        let videos = (0..<10).map { Self.video("v\($0)") }
        list.append(FeedPage(items: videos + [Self.channel("UClate")], continuation: nil))
        #expect(list.items.last?.id == "UClate")
    }

    @Test func aListThinnedByShortsTopsItselfUpWithinItsBudget() {
        var list = FeedList()
        list.userAskedForMore()
        // Each page keeps one video of five items: the list asks again, 5 times, then waits.
        var asked = 0
        for page in 0..<8 {
            list.append(FeedPage(items: [Self.video("v\(page)")] + (0..<4).map { Self.short("s\(page)-\($0)") }, continuation: "more"))
            if list.takeTopUp() { asked += 1 } else { break }
        }
        #expect(asked == FeedList.maxAutomaticPages)
        let again = list.takeTopUp()
        #expect(!again, "at most one yes per landed page")
        // The user scrolls to the end: a fresh budget.
        list.userAskedForMore()
        list.append(FeedPage(items: [Self.short("x")], continuation: "more"))
        let afterScroll = list.takeTopUp()
        #expect(afterScroll)
    }

    @Test func aShortListWithoutShortsOrWithoutANextPageDoesNotTopUp() {
        var plain = FeedList()
        plain.append(FeedPage(items: [Self.video("a")], continuation: "more"))
        let plainTopUp = plain.takeTopUp()
        #expect(!plainTopUp, "short on its own: left as it is")
        var ended = FeedList()
        ended.append(FeedPage(items: [Self.video("a"), Self.short("s")], continuation: nil))
        let endedTopUp = ended.takeTopUp()
        #expect(!endedTopUp)
        var full = FeedList()
        full.append(FeedPage(items: (0..<10).map { Self.video("v\($0)") } + [Self.short("s")], continuation: "more"))
        let fullTopUp = full.takeTopUp()
        #expect(!fullTopUp, "10 kept items scroll")
    }

    @Test func aShortListsEndInViewSharesTheBudgetAndALongOnesRefillsIt() {
        var short = FeedList()
        short.userAskedForMore()
        short.append(FeedPage(items: [Self.video("a"), Self.short("s")], continuation: "more"))
        var asked = 0
        while short.endCameIntoView() {
            asked += 1
            short.append(FeedPage(items: [Self.video("v\(asked)"), Self.short("s\(asked)")], continuation: "more"))
        }
        #expect(asked == FeedList.maxAutomaticPages, "a layout pass is not the user")
        var long = FeedList()
        long.append(FeedPage(items: (0..<12).map { Self.video("v\($0)") }, continuation: "more"))
        for _ in 0..<8 {
            let more = long.endCameIntoView()
            #expect(more, "a scroll to the end of a long list always asks")
        }
        var ended = FeedList()
        ended.append(FeedPage(items: (0..<12).map { Self.video("v\($0)") }, continuation: nil))
        let endedMore = ended.endCameIntoView()
        #expect(!endedMore)
    }

    @Test func theRecordedContinuationKeepsElevenOfTwenty() throws {
        var list = FeedList()
        list.append(try FeedParser.page(try BrowseParserTests.fixture("search_bbb")))
        list.append(try FeedParser.page(try BrowseParserTests.fixture("search_bbb_continuation")))
        #expect(list.items.count == 31 && list.droppedShorts == 9)
    }
}
