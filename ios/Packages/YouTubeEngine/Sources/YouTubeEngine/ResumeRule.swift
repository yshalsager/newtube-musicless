import Foundation

/// Where a video starts when it's opened again (Android's VideoStateController: `restorePosition`,
/// `isStateOutdated`, the reset in `resetPositionIfNeeded`, and Video `getPositionFromPercentWatched`).
public enum ResumeRule {
    /// This phone's record of the video.
    public struct Local: Sendable, Equatable {
        public var position: Double
        public var length: Double
        public var updated: Date
        public init(position: Double, length: Double, updated: Date) {
            self.position = position
            self.length = length
            self.updated = updated
        }
    }

    /// YouTube's red bar for the account (a card's `percentWatched`), and when the card was seen.
    public struct Remote: Sendable, Equatable {
        public var percent: Int
        public var seenAt: Date
        public init(percent: Int, seenAt: Date) {
            self.percent = percent
            self.seenAt = seenAt
        }
    }

    public enum Source: String, Sendable { case local, youtube, none }

    public struct Decision: Sendable, Equatable {
        public var seconds: Double
        public var source: Source
        /// Why it starts at 0 despite a record (`short`, `ended`), for the log.
        public var reset: String?
    }

    /// Videos up to 6 minutes start over (`MUSIC_VIDEO_MAX_DURATION_MS`; Android's "remember the
    /// position of short videos" is off by default).
    public static let shortVideo: Double = 6 * 60
    /// Less than this left counts as ended (`isVideoEnded`).
    public static let endedMargin: Double = 3
    /// YouTube's bar at or under 10 % may be a video opened and closed at once (`RESTORE_POSITION_PERCENTS`).
    public static let remoteMinimum = 10

    public static func decide(length: Double?, local: Local?, remote: Remote?) -> Decision {
        guard let length, length > 0 else { return Decision(seconds: 0, source: .none, reset: nil) }
        var position: Double?
        var source = Source.none
        if let local, local.length > 0 {
            position = min(local.position, length)
            source = .local
        }
        // YouTube's position wins when this phone's record is missing, or older than the card and
        // more than 3 points away from it; long videos only ("web state is buggy on short videos").
        if length > shortVideo, let remote, remote.percent > remoteMinimum, remote.percent < 100 {
            let outdated = local.map { local in
                abs(local.position / local.length * 100 - Double(remote.percent)) > 3 && local.updated < remote.seenAt
            } ?? true
            if outdated {
                position = length * Double(remote.percent) / 100
                source = .youtube
            }
        }
        guard let position, position > 0 else { return Decision(seconds: 0, source: .none, reset: nil) }
        if length - position < endedMargin { return Decision(seconds: 0, source: source, reset: "ended") }
        if length <= shortVideo { return Decision(seconds: 0, source: source, reset: "short") }
        return Decision(seconds: position, source: source, reset: nil)
    }
}
