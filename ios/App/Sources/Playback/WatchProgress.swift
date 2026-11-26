import Foundation
import Observation
import YouTubeEngine

/// How far each video was watched in this app, for the red bar under its thumbnail (Android's
/// VideoStateService, which fills in `percentWatched` where YouTube's card has none). Kept signed
/// in or out, in Application Support, the most recent 1,000 videos.
@MainActor @Observable
final class WatchProgress {
    static let shared = WatchProgress()

    struct Entry: Codable, Equatable {
        var position: Double
        var length: Double
        var updated: Date
    }

    private(set) var entries: [String: Entry] = [:]
    /// YouTube's bars as cards showed them (signed in), and when a card first showed that value:
    /// what this phone never played, or watched elsewhere since.
    private var remote: [String: ResumeRule.Remote] = [:]
    @ObservationIgnored private let storeURL = URL.applicationSupportDirectory.appending(path: "watch-progress.json")
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    static let limit = 1_000

    private init() {
        if let data = try? Data(contentsOf: storeURL), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    func record(videoID: String, position: Double, length: Double) {
        guard length > 0, position.isFinite else { return }
        entries[videoID] = Entry(position: min(max(position, 0), length), length: length, updated: Date())
        if entries.count > Self.limit {
            for (id, _) in entries.sorted(by: { $0.value.updated < $1.value.updated }).prefix(entries.count - Self.limit) {
                entries[id] = nil
            }
        }
        scheduleSave()
    }

    /// 1–100, or nil when the video wasn't played here. A video closed at once still shows a
    /// sliver (1), and the last 5 % count as watched (100), as on Android.
    func percent(_ videoID: String) -> Int? {
        guard let entry = entries[videoID] else { return nil }
        let share = entry.position / entry.length
        if share >= 0.95 { return 100 }
        return max(1, Int((share * 100).rounded()))
    }

    /// The bar a card shows, by resume's rule: this app's own record, unless YouTube's value came
    /// in after it and is more than 3 points away (watched elsewhere since); YouTube's when this
    /// phone never played it.
    func barPercent(videoID: String, youtube: Int?) -> Int? {
        guard let local = entries[videoID] else { return youtube }
        if let youtube, let seen = remote[videoID], seen.percent == youtube, local.updated < seen.seenAt,
           abs(local.position / local.length * 100 - Double(youtube)) > 3 {
            return youtube
        }
        return percent(videoID)
    }

    /// A card with YouTube's bar came on screen. The first sighting of a value is kept, so a list
    /// scrolled again doesn't make an old value look new.
    func noteYouTube(videoID: String, percent: Int?) {
        guard let percent, remote[videoID]?.percent != percent else { return }
        remote[videoID] = ResumeRule.Remote(percent: percent, seenAt: Date())
    }

    /// Where `videoID` starts (ResumeRule, Android's VideoStateController).
    func resume(videoID: String, length: Double?) -> ResumeRule.Decision {
        let local = entries[videoID].map { ResumeRule.Local(position: $0.position, length: $0.length, updated: $0.updated) }
        return ResumeRule.decide(length: length, local: local, remote: remote[videoID])
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONEncoder().encode(entries).write(to: storeURL, options: .atomic)
        }
    }
}
