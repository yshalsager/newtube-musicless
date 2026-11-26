import Foundation
import Testing
@testable import YouTubeEngine

/// Resume (Android's VideoStateController rules).
@Suite struct ResumeRuleTests {
    static let earlier = Date(timeIntervalSince1970: 1_000)
    static let later = Date(timeIntervalSince1970: 2_000)

    static func local(_ position: Double, of length: Double = 600, at date: Date = earlier) -> ResumeRule.Local {
        ResumeRule.Local(position: position, length: length, updated: date)
    }

    @Test func aLongVideoResumesWhereThisPhoneLeftIt() {
        let decision = ResumeRule.decide(length: 600, local: Self.local(250), remote: nil)
        #expect(decision == .init(seconds: 250, source: .local, reset: nil))
    }

    @Test func nothingKnownStartsAtZero() {
        #expect(ResumeRule.decide(length: 600, local: nil, remote: nil).seconds == 0)
        #expect(ResumeRule.decide(length: nil, local: Self.local(250), remote: nil).seconds == 0, "no length yet")
    }

    @Test func shortAndEndedVideosStartOver() {
        let short = ResumeRule.decide(length: 300, local: Self.local(120, of: 300), remote: nil)
        #expect(short.seconds == 0 && short.reset == "short")
        let ended = ResumeRule.decide(length: 600, local: Self.local(598), remote: nil)
        #expect(ended.seconds == 0 && ended.reset == "ended")
        // Exactly 6 minutes is still a short video.
        #expect(ResumeRule.decide(length: 360, local: Self.local(100, of: 360), remote: nil).reset == "short")
    }

    @Test func youtubeFillsInWhenThisPhoneHasNoRecord() {
        let decision = ResumeRule.decide(length: 1_000, local: nil, remote: .init(percent: 40, seenAt: Self.later))
        #expect(decision == .init(seconds: 400, source: .youtube, reset: nil))
    }

    @Test func youtubeWinsOnlyWhenNewerAndMoreThan3PointsAway() {
        let remote = ResumeRule.Remote(percent: 40, seenAt: Self.later)
        // Older local record, far away: YouTube's (watched elsewhere since).
        #expect(ResumeRule.decide(length: 1_000, local: Self.local(100, of: 1_000), remote: remote).source == .youtube)
        // Within 3 points: ours (the same watch, rounded differently).
        #expect(ResumeRule.decide(length: 1_000, local: Self.local(390, of: 1_000), remote: remote).source == .local)
        // Ours is newer than the card: ours.
        let newer = Self.local(100, of: 1_000, at: Date(timeIntervalSince1970: 3_000))
        #expect(ResumeRule.decide(length: 1_000, local: newer, remote: remote).source == .local)
    }

    @Test func youtubeIsIgnoredWhenItCantBeTrusted() {
        // 10 % or less: maybe opened and closed at once. 100: fully watched. Short videos: buggy.
        #expect(ResumeRule.decide(length: 1_000, local: nil, remote: .init(percent: 10, seenAt: Self.later)).seconds == 0)
        #expect(ResumeRule.decide(length: 1_000, local: nil, remote: .init(percent: 100, seenAt: Self.later)).seconds == 0)
        #expect(ResumeRule.decide(length: 300, local: nil, remote: .init(percent: 50, seenAt: Self.later)).seconds == 0)
    }
}
