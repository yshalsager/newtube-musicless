import AVFoundation
import AVKit
import MediaPlayer
import MediaPipeline
import UIKit

/// What the system's controls drive: the lock screen, Control Center, headphones and PiP (US-018).
@MainActor
protocol SystemPlaybackTarget: AnyObject {
    var systemSnapshot: PlayerEngine.Snapshot? { get }
    func systemPlay()
    func systemPause()
    func systemSkip(_ seconds: Double)
    func systemSeek(to seconds: Double)
}

/// Now Playing and the remote commands (US-018): title, channel, artwork, duration, position and
/// rate on the lock screen and in Control Center; play, pause, toggle, ±10 s and scrubbing.
@MainActor
final class NowPlaying {
    static let shared = NowPlaying()

    private weak var target: SystemPlaybackTarget?
    private var info: [String: Any] = [:]
    private var artworkTask: Task<Void, Never>?
    private var commandsInstalled = false

    func begin(target: SystemPlaybackTarget, title: String, author: String, duration: Double?, artwork: URL?) {
        self.target = target
        installCommands()
        info = [MPMediaItemPropertyTitle: title, MPMediaItemPropertyArtist: author,
                MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue]
        publishedRate = -1
        publishedDuration = nil
        if let duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        publish()
        artworkTask?.cancel()
        guard let artwork else { return }
        artworkTask = Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: artwork), let image = UIImage(data: data),
                  !Task.isCancelled else { return }
            self?.info[MPMediaItemPropertyArtwork] = Self.artwork(image)
            self?.publish()
        }
    }

    /// Position and rate. The system extrapolates the position from them, so they are published only
    /// when the rate or duration changes (play, pause, a hold, a speed) or the position jumps (a seek).
    func update(_ snapshot: PlayerEngine.Snapshot) {
        guard target != nil else { return }
        let rate = snapshot.status == .playing ? Double(snapshot.speed) : 0
        let expected = publishedElapsed + publishedRate * secondsSincePublish
        guard rate != publishedRate || snapshot.duration != publishedDuration || abs(snapshot.position - expected) > 0.5
                || info[MPNowPlayingInfoPropertyElapsedPlaybackTime] == nil else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = snapshot.position
        info[MPNowPlayingInfoPropertyPlaybackRate] = rate
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        if let duration = snapshot.duration { info[MPMediaItemPropertyPlaybackDuration] = duration }
        publishedElapsed = snapshot.position
        publishedRate = rate
        publishedDuration = snapshot.duration
        publishedAt = .now
        publish()
    }

    /// For the system check: how long ago position and rate were published, and how many times.
    var secondsSincePublish: Double { (ContinuousClock.now - publishedAt) / .milliseconds(1) / 1000 }
    private(set) var publishes = 0
    private var publishedElapsed = 0.0
    private var publishedRate = -1.0
    private var publishedDuration: Double?
    private var publishedAt = ContinuousClock.now

    func end() {
        target = nil
        artworkTask?.cancel()
        info = [:]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    /// MediaPlayer calls the artwork's handler on its own queue: it must not be main-actor isolated,
    /// which a closure written inside this class would be (and the runtime check traps).
    nonisolated private static func artwork(_ image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { @Sendable _ in image }
    }

    private func publish() {
        publishes += 1
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func installCommands() {
        guard !commandsInstalled else { return }
        commandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in self?.run { $0.systemPlay() } ?? .noActionableNowPlayingItem }
        center.pauseCommand.addTarget { [weak self] _ in self?.run { $0.systemPause() } ?? .noActionableNowPlayingItem }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            self?.run { $0.systemSnapshot?.wantsToPlay == false ? $0.systemPlay() : $0.systemPause() } ?? .noActionableNowPlayingItem
        }
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        center.skipForwardCommand.addTarget { [weak self] _ in self?.run { $0.systemSkip(10) } ?? .noActionableNowPlayingItem }
        center.skipBackwardCommand.addTarget { [weak self] _ in self?.run { $0.systemSkip(-10) } ?? .noActionableNowPlayingItem }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            return self?.run { $0.systemSeek(to: event.positionTime) } ?? .noActionableNowPlayingItem
        }
        AppLog.player.info("now-playing remote commands installed")
    }

    /// Remote commands arrive on the main thread.
    nonisolated private func run(_ action: @MainActor (SystemPlaybackTarget) -> Void) -> MPRemoteCommandHandlerStatus {
        MainActor.assumeIsolated {
            guard let target else { return .noActionableNowPlayingItem }
            action(target)
            return .success
        }
    }
}

/// Picture in Picture from the engine's display layer (US-018; PRD §4.2), started automatically when
/// the user leaves the app while the video plays. While it is active the picture keeps decoding: the
/// background rule that stops feeding the layer doesn't apply.
@MainActor
final class PictureInPicture: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
    private var controller: AVPictureInPictureController!
    private weak var target: SystemPlaybackTarget?
    /// Starting or running.
    private(set) var isActive = false
    /// PiP closed (by the user or the system); the screen decides whether the picture keeps decoding.
    var onStop: (() -> Void)?
    var isPossible: Bool { controller.isPictureInPicturePossible }

    init?(layer: AVSampleBufferDisplayLayer, target: SystemPlaybackTarget) {
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return nil }
        self.target = target
        super.init()
        controller = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: layer, playbackDelegate: self))
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
    }

    func start() { controller.startPictureInPicture() }
    func stop() { controller.stopPictureInPicture() }

    /// The play state, time range and pause flag changed: PiP asks again.
    func invalidate() { controller.invalidatePlaybackState() }

    // MARK: AVPictureInPictureControllerDelegate

    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isActive = true
            AppLog.player.info("pip will-start appState=\(AppActivity.logValue)")
        }
    }

    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated { AppLog.player.info("pip started appState=\(AppActivity.logValue)") }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: any Error) {
        MainActor.assumeIsolated {
            isActive = false
            AppLog.player.info("pip failed error=\(error)")
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isActive = false
            AppLog.player.info("pip stopped appState=\(AppActivity.logValue)")
            onStop?()
        }
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate (called on the main thread)

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated { playing ? target?.systemPlay() : target?.systemPause() }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            let duration = target?.systemSnapshot?.duration ?? 0
            return duration > 0 ? CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
                : CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { target?.systemSnapshot?.wantsToPlay == false }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { target?.systemSkip(skipInterval.seconds) }
        completionHandler()
    }
}
