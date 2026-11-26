import Foundation
import os
import Testing
@testable import YouTubeEngine

/// US-017: the one-minute wall's signature, memory and re-roll budget (MediaServiceCore's
/// `PlaybackWallMemory` and `notePlaybackMedia403`).
@Suite struct WallBookTests {
    @Test func theSignatureReadsTheRequestStarts() {
        // The device's walled visitor: refused at 60.0 s after requests from 0 to 54 s were served.
        #expect(WallBook.classify(forbiddenMs: 60_001, lowestServedMs: 0, highestServedMs: 54_054) == .wall)
        // The first links refused at 0 s, or a stale link minutes in after media past 65 s played.
        #expect(WallBook.classify(forbiddenMs: 0, lowestServedMs: -1, highestServedMs: -1) == .ordinary)
        #expect(WallBook.classify(forbiddenMs: 54_999, lowestServedMs: 0, highestServedMs: 50_000) == .ordinary)
        #expect(WallBook.classify(forbiddenMs: 300_000, lowestServedMs: 0, highestServedMs: 66_000) == .ordinary)
        // A seek straight past the wall: nothing served below it (none, or only between 60 and 65 s).
        #expect(WallBook.classify(forbiddenMs: 70_000, lowestServedMs: -1, highestServedMs: -1) == .ambiguous)
        #expect(WallBook.classify(forbiddenMs: 70_000, lowestServedMs: 61_000, highestServedMs: 62_000) == .ambiguous)
        // Something served from 65 s on: past-the-wall media played, so this 403 is something else.
        #expect(WallBook.classify(forbiddenMs: 70_000, lowestServedMs: 70_000, highestServedMs: 70_000) == .ordinary)
    }

    @Test func aWallIsRememberedForItsVisitorAndBenchesTheSourceInTheRecovery() async {
        let clock = WallClock()
        let book = WallBook(storeURL: nil, now: { clock.date })
        let verdict = await book.noteMedia403(videoID: "v1", client: .visionOS, visitor: "visitor-a", forbiddenMs: 60_001,
                                              lowestServedMs: 0, highestServedMs: 54_054)
        #expect(verdict.signature == .wall && verdict.how == "served-below" && verdict.rerollWanted)
        // The recovery benches VISIONOS; another video's first walk too, while the visitor is the same.
        #expect(await book.plan(videoID: "v1", recovery: true, appVisitor: "visitor-a").benched == [.visionOS])
        #expect(await book.plan(videoID: "v2", recovery: false, appVisitor: "visitor-a").benched == [.visionOS])
        // A re-rolled visitor: the memory doesn't apply, and the recovery asks VISIONOS again as refreshed.
        let rerolled = await book.plan(videoID: "v1", recovery: true, appVisitor: "visitor-b")
        #expect(rerolled.benched.isEmpty && rerolled.refreshed == [.visionOS])
        // Six hours later it's forgotten.
        clock.advance(seconds: 6 * 3_600 + 1)
        #expect(await book.plan(videoID: "v2", recovery: false, appVisitor: "visitor-a").benched.isEmpty)
    }

    @Test func anOrdinary403BenchesNothingAndAnAmbiguousOneNeedsConfirmation() async {
        let book = WallBook(storeURL: nil)
        let ordinary = await book.noteMedia403(videoID: "v1", client: .webEmbed, visitor: nil, forbiddenMs: 0,
                                               lowestServedMs: -1, highestServedMs: -1)
        #expect(ordinary.signature == .ordinary && ordinary.how == nil)
        #expect(await book.plan(videoID: "v1", recovery: true, appVisitor: "a").benched.isEmpty,
                "a kids video's WEB_EMBED stays one of its two servers")
        let first = await book.noteMedia403(videoID: "v2", client: .visionOS, visitor: "a", forbiddenMs: 90_000,
                                            lowestServedMs: -1, highestServedMs: -1)
        #expect(first.signature == .ambiguous && first.how == nil, "a seek past 60 s alone proves nothing")
        let second = await book.noteMedia403(videoID: "v2", client: .tvTizen, visitor: "a", forbiddenMs: 90_000,
                                             lowestServedMs: -1, highestServedMs: -1)
        #expect(second.how == "confirmed", "a second source refused past the wall on the same video")
        #expect(await book.plan(videoID: "v3", recovery: false, appVisitor: "a").benched == [.visionOS, .tvTizen])
    }

    @Test func theVisitorIsReRolledTwicePerSixHoursAndOncePerVideo() async {
        let clock = WallClock()
        let book = WallBook(storeURL: nil, now: { clock.date })
        #expect(await book.spendReroll(videoID: "v1"))
        #expect(await !book.spendReroll(videoID: "v1"), "once per video")
        #expect(await book.spendReroll(videoID: "v2"))
        #expect(await !book.spendReroll(videoID: "v3"), "2 per 6 h")
        clock.advance(seconds: 6 * 3_600 + 1)
        #expect(await book.spendReroll(videoID: "v3"))
    }

    @Test func theMemoryPersistsAndNeverHoldsAVisitor() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "walls-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let book = WallBook(storeURL: url)
        _ = await book.noteMedia403(videoID: "v1", client: .androidVR, visitor: "CgtSecretVisitor", forbiddenMs: 60_000,
                                    lowestServedMs: 0, highestServedMs: 50_000)
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains("CgtSecretVisitor"), "only a fingerprint is stored")
        let restored = WallBook(storeURL: url)
        #expect(await restored.plan(videoID: "v9", recovery: false, appVisitor: "CgtSecretVisitor").benched == [.androidVR])
    }
}

final class WallClock: Sendable {
    private let offset = OSAllocatedUnfairLock(initialState: 0.0)
    var date: Date { Date(timeIntervalSince1970: 1_790_000_000 + offset.withLock { $0 }) }
    func advance(seconds: Double) { offset.withLock { $0 += seconds } }
}
