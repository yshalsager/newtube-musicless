import Foundation
import Observation
import YouTubeEngine

/// Watch later, signed in (Android's "Add to Watch later" card item, on by default, and You →
/// Playlists → Watch later). Remembers what this app saved or saw in the list, so the watch page
/// and the card menus say "Saved" for those.
@MainActor @Observable
final class WatchLater {
    static let shared = WatchLater()

    private(set) var saved: Set<String> = []
    private(set) var pending: Set<String> = []
    /// Bumped on each change, for the haptic.
    private(set) var changes = 0
    private(set) var failures = 0

    func isSaved(_ videoID: String) -> Bool { saved.contains(videoID) }

    /// The Watch later list was loaded: its videos are saved.
    func noteListed(_ videoIDs: [String]) { saved.formUnion(videoIDs) }

    func toggle(_ videoID: String) async {
        await set(videoID, saved: !isSaved(videoID))
    }

    func set(_ videoID: String, saved wanted: Bool) async {
        guard !pending.contains(videoID) else { return }
        pending.insert(videoID)
        defer { pending.remove(videoID) }
        do {
            try await PlaybackServices.shared.browse.setWatchLater(videoID, saved: wanted)
            if wanted { saved.insert(videoID) } else { saved.remove(videoID) }
            changes += 1
        } catch {
            AppLog.netPath.info("watch-later failed video=\(videoID) error=\(error)")
            failures += 1
        }
    }
}
