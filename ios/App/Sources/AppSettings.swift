import Foundation
import Observation

/// The app's own settings, in UserDefaults (US-020, US-023, US-024; the Settings screen shows them).
/// Defaults are the musicless fork's (`BuildConfig.MUSICLESS_FORK` in the Android prefs and its first
/// run in MobileMainApplication).
@MainActor @Observable
final class AppSettings {
    static let shared = AppSettings()

    /// The video quality cap: the short side in pixels (1080 is the most H.264 has, US-034).
    enum MaxQuality: Int, CaseIterable, Identifiable {
        case p1080 = 1080, p720 = 720, p480 = 480, p360 = 360, p240 = 240
        var id: Int { rawValue }
        var label: String { "\(rawValue)p" }
    }

    private enum Key {
        static let showUpNext = "showUpNext"
        static let showHome = "showHome"
        static let removeMusic = "removeMusic"
        static let maxQuality = "maxQuality"
        static let prefer60fps = "prefer60fps"
        static let backgroundPlay = "backgroundPlay"
    }

    @ObservationIgnored private let defaults: UserDefaults

    /// Related videos under the player ("Up next"). Off by default: PlayerTweaksData's
    /// `mIsSuggestionsDisabled` defaults to true in the musicless fork.
    var showUpNext: Bool {
        didSet { defaults.set(showUpNext, forKey: Key.showUpNext) }
    }

    /// The Home tab. Off by default: the fork starts without it (MobileMainApplication's first run:
    /// "YouTube's signed-out Home can't be filtered"), and the app opens on Subscriptions anyway.
    var showHome: Bool {
        didSet { defaults.set(showHome, forKey: Key.showHome) }
    }

    /// Music removal, on by default in the fork (MusiclessPrefs). The player menu's switch is this
    /// setting, as on Android.
    var removeMusic: Bool {
        didSet { defaults.set(removeMusic, forKey: Key.removeMusic) }
    }

    var maxQuality: MaxQuality {
        didSet { defaults.set(maxQuality.rawValue, forKey: Key.maxQuality) }
    }

    /// 60 fps files when there's a choice at the same size.
    var prefer60fps: Bool {
        didSet { defaults.set(prefer60fps, forKey: Key.prefer60fps) }
    }

    /// Keep playing (the voices) when the app leaves the screen or the phone locks; off pauses.
    /// Picture in Picture keeps playing either way.
    var backgroundPlay: Bool {
        didSet { defaults.set(backgroundPlay, forKey: Key.backgroundPlay) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // `--up-next` (debug) shows it for this launch without saving (didSet doesn't run in init).
        showUpNext = ProcessInfo.processInfo.arguments.contains("--up-next") || defaults.object(forKey: Key.showUpNext) as? Bool ?? false
        showHome = defaults.object(forKey: Key.showHome) as? Bool ?? false
        removeMusic = defaults.object(forKey: Key.removeMusic) as? Bool ?? true
        maxQuality = MaxQuality(rawValue: defaults.integer(forKey: Key.maxQuality)) ?? .p1080
        prefer60fps = defaults.object(forKey: Key.prefer60fps) as? Bool ?? true
        backgroundPlay = defaults.object(forKey: Key.backgroundPlay) as? Bool ?? true
    }
}
