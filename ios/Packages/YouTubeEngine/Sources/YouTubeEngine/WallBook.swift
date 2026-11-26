import CryptoKit
import Foundation

/// The one-minute wall (US-017; HANDOFF §34, LANES §2.3), ported from MediaServiceCore's
/// `PlaybackWallMemory` and `VideoInfoService.notePlaybackMedia403` / `wallPlan`: googlevideo serves
/// a walled (visitor, source) pair exactly 60 s of stream, then refuses every request starting past
/// it. A media 403 is read against the open's request starts; a wall is remembered for 6 h (those
/// sources go last while they would send that visitor), benches the source for the video's recovery,
/// and — for VISIONOS or ANDROID_VR — re-rolls the visitor (2 per 6 h, once per video).
///
/// iOS has one re-rollable visitor (the youtube.com/tv one, D46) where Android re-rolls the web
/// session's; WEB_EMBED's embed identity is not remembered (its 152 refusal drops it already).
public actor WallBook {
    public enum Signature: String, Sendable {
        /// Not the wall: refused before 55 s of stream, or media past 65 s was served.
        case ordinary
        /// Refused at or past 55 s after a request below 60 s was served, nothing served past 65 s.
        case wall
        /// Refused past the wall with nothing served below it (a resume or seek straight past 60 s).
        case ambiguous
    }

    public struct Verdict: Sendable {
        public var signature: Signature
        /// How a wall was established (`served-below`, `known`, `confirmed`); nil when it wasn't.
        public var how: String?
        /// VISIONOS or ANDROID_VR walled: the visitor should be re-rolled (if the budget allows).
        public var rerollWanted: Bool
    }

    public static let wallMs: Int64 = 60_000
    public static let toleranceMs: Int64 = 5_000
    public static let memoryTTL: TimeInterval = 6 * 3_600
    public static let memoryCapacity = 32
    public static let video403TTL: TimeInterval = 30 * 60
    public static let rerollBudget = 2
    public static let rerollWindow: TimeInterval = 6 * 3_600

    /// PlaybackWallMemory.classify.
    public static func classify(forbiddenMs: Int64, lowestServedMs: Int64, highestServedMs: Int64) -> Signature {
        if forbiddenMs < wallMs - toleranceMs { return .ordinary }
        if highestServedMs >= wallMs + toleranceMs { return .ordinary }
        return lowestServedMs >= 0 && lowestServedMs < wallMs ? .wall : .ambiguous
    }

    /// A visitor as the memory keys it: 10 hex characters of its SHA-256 (never the visitor itself).
    public static func fingerprint(_ visitor: String?) -> String? {
        guard let visitor, !visitor.isEmpty else { return nil }
        return SHA256.hash(data: Data(visitor.utf8)).prefix(5).map { String(format: "%02x", $0) }.joined()
    }

    private struct Stored: Codable {
        var walls: [String: Date] = [:]  // "<fingerprint>|<client>" -> expiry
        var rerolls: [Date] = []
    }

    private struct Video403 {
        /// Sources whose media 403'd past the wall on this video, with the visitor they sent.
        var clients: [ClientProfile: String?] = [:]
        var pastWallUnconfirmed: [ClientProfile: String?] = [:]
        var lastAt = Date.distantPast
    }

    private let storeURL: URL?
    private let now: @Sendable () -> Date
    private let log: @Sendable (String) -> Void
    private var stored = Stored()
    private var videos: [String: Video403] = [:]
    private var rerolledVideos: Set<String> = []

    public init(storeURL: URL?, now: @escaping @Sendable () -> Date = { Date() }, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.storeURL = storeURL
        self.now = now
        self.log = log
        if let storeURL, let data = try? Data(contentsOf: storeURL), let decoded = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = decoded
        }
    }

    /// notePlaybackMedia403: `client`'s media for `videoID` was refused at `forbiddenMs` of stream;
    /// the open's requests that were served started between `lowestServedMs` and `highestServedMs`
    /// (-1: none). `visitor` is the visitor the answer was requested with.
    public func noteMedia403(videoID: String, client: ClientProfile, visitor: String?, forbiddenMs: Int64,
                             lowestServedMs: Int64, highestServedMs: Int64) -> Verdict {
        let time = now()
        let fingerprint = Self.fingerprint(visitor)
        let signature = Self.classify(forbiddenMs: forbiddenMs, lowestServedMs: lowestServedMs, highestServedMs: highestServedMs)
        log("playback-media403 video=\(videoID) client=\(client.id) forbiddenStartMs=\(forbiddenMs) "
            + "servedStartMs=\(lowestServedMs)..\(highestServedMs) signature=\(signature.rawValue)")
        var video = videos[videoID].flatMap { time.timeIntervalSince($0.lastAt) <= Self.video403TTL ? $0 : nil } ?? Video403()
        var how: String?
        var confirmed: [ClientProfile: String?] = [:]
        if signature != .ordinary {
            // Only past the wall: an ordinary 403 is answered by fresh links from the same source.
            video.clients[client] = fingerprint
            video.lastAt = time
        }
        switch signature {
        case .wall: how = "served-below"
        case .ambiguous:
            if isWalled(fingerprint, client, at: time) {
                how = "known"
            } else if !video.pastWallUnconfirmed.isEmpty {
                how = "confirmed"  // a reload or another source refused past the wall too
            } else {
                video.pastWallUnconfirmed[client] = fingerprint
            }
        case .ordinary: break
        }
        if how != nil, !video.pastWallUnconfirmed.isEmpty {
            confirmed = video.pastWallUnconfirmed
            video.pastWallUnconfirmed = [:]
        }
        videos[videoID] = video
        guard signature != .ordinary else { return Verdict(signature: signature, how: nil, rerollWanted: false) }
        guard let how else {
            log("playback-wall-unconfirmed video=\(videoID) client=\(client.id) visitor=\(fingerprint ?? "?")")
            return Verdict(signature: signature, how: nil, rerollWanted: false)
        }
        var walls = confirmed
        walls[client] = fingerprint
        var rerollWanted = false
        for (walled, visitorFingerprint) in walls {
            if let visitorFingerprint { stored.walls["\(visitorFingerprint)|\(walled.id)"] = time.addingTimeInterval(Self.memoryTTL) }
            if walled == .visionOS || walled == .androidVR { rerollWanted = true }
        }
        trimAndPersist(at: time)
        log("playback-wall video=\(videoID) client=\(client.id) visitor=\(fingerprint ?? "?") how=\(how) "
            + "forbiddenStartMs=\(forbiddenMs) servedStartMs=\(lowestServedMs)..\(highestServedMs)"
            + (confirmed.isEmpty ? "" : " confirms=\(confirmed.keys.map(\.id).sorted())"))
        return Verdict(signature: signature, how: how, rerollWanted: rerollWanted)
    }

    /// Spends one re-roll for `videoID` (once per video, 2 per 6 h); false when it can't.
    public func spendReroll(videoID: String) -> Bool {
        let time = now()
        stored.rerolls = stored.rerolls.filter { time.timeIntervalSince($0) < Self.rerollWindow }
        guard !rerolledVideos.contains(videoID) else {
            log("playback-identity reroll-skip reason=once-per-video video=\(videoID)")
            return false
        }
        guard stored.rerolls.count < Self.rerollBudget else {
            log("playback-identity reroll-skip reason=budget video=\(videoID)")
            return false
        }
        stored.rerolls.append(time)
        rerolledVideos.insert(videoID)
        trimAndPersist(at: time)
        log("playback-identity reroll-armed video=\(videoID) budgetLeft=\(Self.rerollBudget - stored.rerolls.count)")
        return true
    }

    /// wallPlan: the sources a walk asks last (`benched`) and, in `videoID`'s recovery, those that
    /// walled here but whose visitor has been re-rolled since (`refreshed`).
    public func plan(videoID: String, recovery: Bool, appVisitor: String?) -> (benched: Set<ClientProfile>, refreshed: Set<ClientProfile>) {
        let time = now()
        let current = Self.fingerprint(appVisitor)
        var benched = Set<ClientProfile>(), refreshed = Set<ClientProfile>()
        if recovery, let video = videos[videoID], time.timeIntervalSince(video.lastAt) <= Self.video403TTL {
            for (client, sent) in video.clients {
                if client.identity == .appVisitor, let sent, sent != current {
                    refreshed.insert(client)
                } else {
                    benched.insert(client)
                }
            }
        }
        if let current {
            for client in SourcePlanner.baseOrder where client.identity == .appVisitor && isWalled(current, client, at: time) {
                benched.insert(client)
                refreshed.remove(client)
            }
        }
        return (benched, refreshed)
    }

    private func isWalled(_ fingerprint: String?, _ client: ClientProfile, at time: Date) -> Bool {
        guard let fingerprint, let until = stored.walls["\(fingerprint)|\(client.id)"] else { return false }
        return time < until
    }

    private func trimAndPersist(at time: Date) {
        stored.walls = stored.walls.filter { time < $0.value }
        if stored.walls.count > Self.memoryCapacity {
            for key in stored.walls.sorted(by: { $0.value < $1.value }).prefix(stored.walls.count - Self.memoryCapacity).map(\.key) {
                stored.walls[key] = nil
            }
        }
        guard let storeURL, let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: storeURL, options: .atomic)
    }
}
