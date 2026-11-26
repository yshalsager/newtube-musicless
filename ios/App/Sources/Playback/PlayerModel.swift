import AVFoundation
import AVKit
import MediaPlayer
import Foundation
import MediaPipeline
import MusiclessCore
import Observation
import SwiftUI
import UIKit
import YouTubeEngine

/// The player: resolves a video, runs the engine (picture and voices), and joins the system's
/// controls (Now Playing, PiP, the idle timer). The watch page (US-020) and the debug watch screen
/// (US-014) both drive it; the debug checks are in Debug/PlayerChecks.swift.
@MainActor @Observable
final class PlayerModel: SystemPlaybackTarget {
    struct Preset: Identifiable, Hashable {
        let id: String
        let title: String
        let expect: String
    }

    /// Music-heavy videos for the ear test (PRD US-012), each testing a different mix.
    static let presets = [
        Preset(id: "aqz-KE-bpKQ", title: "Big Buck Bunny", expect: "Orchestral score, no speech: should be near silence"),
        Preset(id: "eRsGyueVLvQ", title: "Sintel", expect: "Dialogue over a loud score: voices only"),
        Preset(id: "h6fcK_fRYaI", title: "Kurzgesagt: The Egg", expect: "Narration over music: narration only"),
        Preset(id: "dQw4w9WgXcQ", title: "Rick Astley: Never Gonna Give You Up", expect: "A song: the singing without the band"),
    ]

    private(set) var title = ""
    /// The video playing (or resolving); nil when stopped.
    private(set) var videoID: String?
    private(set) var detail = ""
    private(set) var snapshot: PlayerEngine.Snapshot?
    private(set) var error: String?
    private(set) var resolving = false
    /// The picture of the current video; a new layer per video.
    private(set) var layer: AVSampleBufferDisplayLayer?
    private(set) var qualities: [VideoOption] = []
    private(set) var quality: VideoOption?
    /// Music removal: the setting (the player menu's switch changes it, as on Android).
    var removeMusic = AppSettings.shared.removeMusic
    /// Plays the voices without the picture (US-012's mode).
    var audioOnly = false

    /// Debug (US-017): the first answer's links refuse past 60 s of stream (`--synthetic-wall`).
    var syntheticWall = ProcessInfo.processInfo.arguments.contains("--synthetic-wall")
        || ProcessInfo.processInfo.arguments.contains("--wall-check")

    @ObservationIgnored private let models: ModelStore
    // Internal, not private: the debug checks (Debug/PlayerChecks.swift) drive them.
    /// The YouTube engine, or a local file's (US-027).
    @ObservationIgnored var engine: (any PlaybackEngine)?
    /// A local file's security-scoped access, released on stop.
    @ObservationIgnored private var localFile: URL?
    @ObservationIgnored var playing: PlayingFiles?
    @ObservationIgnored var pip: PictureInPicture?
    @ObservationIgnored private var nowPlayingTitle = ""
    @ObservationIgnored private var nowPlayingArtwork: URL?
    /// The speeds the picker offers (US-018).
    static let speeds: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    private(set) var speed: Float = 1
    /// The full-screen landscape view is showing.
    var fullScreen = false
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var tapAt: ContinuousClock.Instant?
    @ObservationIgnored private var playerMs = 0
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    /// The start ping went for this video.
    @ObservationIgnored private var historyStarted = false
    /// Where the red bar's record was last written (WatchProgress), in seconds.
    @ObservationIgnored private var progressRecordedAt: Double = 0

    init(models: ModelStore) {
        self.models = models
        PlaybackAudioSession.shared.onPlayChange = { [weak self] play in
            guard let engine = self?.engine else { return }
            Task { play ? await engine.play() : await engine.pause() }
        }
        // Background without PiP (PRD §4.2): stop feeding the picture; catch it up on the way back.
        let center = NotificationCenter.default
        // With PiP running (it starts as the app leaves), the picture keeps decoding.
        for (name, active) in [(UIApplication.didEnterBackgroundNotification, false),
                               (UIApplication.willEnterForegroundNotification, true),
                               (UIApplication.didBecomeActiveNotification, true)] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let engine = self.engine else { return }
                    if active {
                        Task { await engine.setVideoActive(true) }
                        self.updateIdleTimer()
                        return
                    }
                    UIApplication.shared.isIdleTimerDisabled = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))  // PiP's will-start comes during the transition
                        if self.pip?.isActive == true {
                            AppLog.player.info("video stays on (pip) appState=\(AppActivity.logValue)")
                        } else {
                            await engine.setVideoActive(false)
                            // Background play off (Settings): pause, unless PiP keeps it on screen.
                            if !AppSettings.shared.backgroundPlay {
                                AppLog.player.info("voices pause reason=background-play-off appState=\(AppActivity.logValue)")
                                await engine.pause()
                            }
                        }
                    }
                }
            })
        }
    }

    var isActive: Bool { engine != nil }

    /// The resolved title when `id` is the video playing (the watch page shows it before `/next`).
    func titleIfResolved(_ id: String) -> String? {
        videoID == id && !resolving && title != id && !title.isEmpty ? title : nil
    }

    var statusText: String {
        if let error { return "Failed: \(error)" }
        if resolving { return "Resolving…" }
        guard let snapshot else { return "Paste a link or pick a video" }
        switch snapshot.status {
        case .idle: return "Stopped"
        case .loading: return "Opening…"
        case .holding: return waitingText
        case .playing: return snapshot.removeMusic ? "Playing voices only" : "Playing the original audio"
        case .paused: return "Paused"
        case .ended: return "Ended"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    /// While holding: the models' download (playback waits for it) or the separation itself.
    var waitingText: String {
        guard snapshot?.removeMusic != false else { return String(localized: "Loading…") }
        switch models.status {
        case .downloading(let percent): return String(localized: "Downloading voice models… \(percent)%")
        case .notDownloaded: return String(localized: "Downloading voice models…")
        case .failed(let message): return String(localized: "Voice models failed: \(message)")
        case .ready: return String(localized: "Preparing voices…")
        }
    }

    var isHolding: Bool {
        if case .holding = snapshot?.status { true } else { false }
    }

    func play(_ link: VideoLink) async {
        await play(link.videoID, at: link.startSeconds ?? 0)
    }

    /// - resume: start where the viewer left it (ResumeRule) instead of at `seconds`; the watch
    ///   page asks for it, a link's own `t=` and the debug screens don't.
    func play(_ videoID: String, at seconds: Double = 0, resume: Bool = false) async {
        var seconds = seconds
        await stop(reason: "new video")
        generation += 1
        let token = generation
        error = nil
        resolving = true
        title = videoID
        self.videoID = videoID
        tapAt = .now
        removeMusic = AppSettings.shared.removeMusic
        AppLog.player.info("voices tap video=\(videoID) at=\(seconds) removeMusic=\(removeMusic) audioOnly=\(audioOnly)")
        do {
            let media = try await VideoResolver.media(for: videoID, withVideo: !audioOnly, synthetic: syntheticWall)
            guard token == generation else { return }
            if resume {
                let decision = WatchProgress.shared.resume(videoID: videoID, length: media.lengthSeconds)
                seconds = decision.seconds
                AppLog.player.info("voices resume video=\(videoID) at=\(Int(decision.seconds)) source=\(decision.source.rawValue)"
                                   + (decision.reset.map { " reset=\($0)" } ?? "") + " len=\(Int(media.lengthSeconds ?? 0))")
            }
            title = media.title
            qualities = media.videoOptions
            quality = media.videoOptions.first { $0.source.file.itag == media.video?.file.itag }
            detail = [media.author, "itag \(media.audio.file.itag)"].joined(separator: " · ")
            playerMs = media.playerMs
            try PlaybackAudioSession.shared.activate()
            let backend = PlaybackServices.shared.playerBackend(models: models)
            let separator = Separator(backend: backend, log: { line in
                AppLog.musicless.info(line.hasPrefix("Window pipeline") ? line + " appState=\(AppActivity.logValue)" : line)
            })
            var video: VideoInput?
            if let picture = media.video {
                let layer = AVSampleBufferDisplayLayer()
                layer.videoGravity = .resizeAspect
                layer.backgroundColor = UIColor.black.cgColor
                self.layer = layer
                video = VideoInput(source: picture, fetcher: Self.fetcher(picture), renderer: layer.sampleBufferRenderer)
                pip = PictureInPicture(layer: layer, target: self)
                // PiP closed while the app is away: the background rule applies again.
                pip?.onStop = { [weak self] in
                    guard let engine = self?.engine, UIApplication.shared.applicationState == .background else { return }
                    Task { await engine.setVideoActive(false) }
                }
            }
            nowPlayingTitle = media.title
            nowPlayingArtwork = media.thumbnail
            NowPlaying.shared.begin(target: self, title: media.title, author: media.author, duration: nil, artwork: media.thumbnail)
            var configuration = PlayerEngine.Configuration()
            configuration.audioDelay = media.audioDelay
            if syntheticWall { configuration.syntheticWallSeconds = 60 }
            let playing = PlayingFiles(media)
            self.playing = playing
            let synthetic = syntheticWall
            let engine = PlayerEngine(
                audio: media.audio, fetcher: Self.fetcher(media.audio),
                stage: SeparatorStage(separator: separator), video: video, configuration: configuration,
                recover: { refusal in
                    await VideoResolver.recover(videoID: videoID, playing: playing, refusal: refusal, synthetic: synthetic)
                },
                log: { AppLog.player.info($0 + " appState=\(AppActivity.logValue)") },
                holdLog: { AppLog.musicless.info($0) },
                onChange: { [weak self] snapshot in Task { @MainActor in self?.changed(snapshot) } })
            self.engine = engine
            if speed != 1 { await engine.setSpeed(speed) }
            resolving = false
            AppLog.player.info("voices resolved video=\(videoID) title=\"\(media.title)\" video=\"\(media.videoLabel ?? "none")\" "
                               + "qualities=\(media.videoOptions.map(\.label).joined(separator: ",")) playerMs=\(media.playerMs)")
            startPolling()
            await engine.start(at: seconds, removeMusic: removeMusic)
        } catch {
            guard token == generation else { return }
            resolving = false
            self.error = "\(error)"
            AppLog.player.info("voices failed video=\(videoID) error=\(error)")
        }
    }

    private static func fetcher(_ source: FMP4Source) -> MediaFetcher {
        MediaFetcher(file: source.file, log: { AppLog.netPath.info($0) })
    }

    /// Play/pause; at the end (the video stays paused there, PLAYBACK_MODE_PAUSE) it replays.
    func togglePlay() async {
        guard let engine, let snapshot else { return }
        if snapshot.status == .ended {
            await engine.seek(to: 0)
            await engine.play()
        } else {
            snapshot.wantsToPlay ? await engine.pause() : await engine.play()
        }
        self.snapshot = await engine.snapshot()
    }

    func seek(to seconds: Double) async {
        await engine?.seek(to: seconds)
    }

    func skip(_ seconds: Double) async {
        guard let snapshot else { return }
        await seek(to: snapshot.position + seconds)
    }

    func setSpeed(_ value: Float) async {
        speed = value
        await engine?.setSpeed(value)
        if let engine { changed(await engine.snapshot()) }
    }

    func startPictureInPicture() { pip?.start() }

    // MARK: SystemPlaybackTarget (lock screen, Control Center, PiP)

    var systemSnapshot: PlayerEngine.Snapshot? { snapshot }
    func systemPlay() {
        Task {
            if snapshot?.status == .ended { await togglePlay() } else { await engine?.play() }
            await refresh()
        }
    }
    func systemPause() { Task { await engine?.pause(); await refresh() } }
    func systemSkip(_ seconds: Double) { Task { await skip(seconds); await refresh() } }
    func systemSeek(to seconds: Double) { Task { await seek(to: seconds); await refresh() } }

    private func refresh() async {
        guard let engine else { return }
        changed(await engine.snapshot())
    }

    private func updateIdleTimer() {
        // The screen doesn't sleep while a picture plays in the foreground (US-018).
        UIApplication.shared.isIdleTimerDisabled = layer != nil && snapshot?.status == .playing
            && UIApplication.shared.applicationState == .active
    }

    func setRemoveMusic(_ on: Bool) async {
        removeMusic = on
        if AppSettings.shared.removeMusic != on { AppSettings.shared.removeMusic = on }
        await engine?.setRemoveMusic(on)
    }

    func setQuality(_ option: VideoOption) async {
        guard let engine = engine as? PlayerEngine, option != quality else { return }
        quality = option
        AppLog.player.info("voices quality=\(option.label) itag=\(option.itag)")
        do {
            try await engine.switchVideo(to: option.source, fetcher: Self.fetcher(option.source))
            await playing?.video(option.source.file)
        } catch {
            AppLog.player.info("voices quality failed error=\(error)")
        }
    }

    /// Ends playback; `reason` goes to the log (`voices stop reason=…`).
    func stop(reason: String) async {
        poll?.cancel()
        poll = nil
        if let videoID, let snapshot, let length = snapshot.duration, snapshot.status != .ended, historyStarted {
            let history = PlaybackServices.shared.history, position = snapshot.position
            WatchProgress.shared.record(videoID: videoID, position: position, length: length)
            Task { await history.report(videoID: videoID, position: position, length: length, event: "stop") }
        }
        historyStarted = false
        progressRecordedAt = 0
        if let engine {
            AppLog.player.info("voices stop reason=\(reason) appState=\(AppActivity.logValue)")
            self.engine = nil
            pip?.stop()
            pip = nil
            NowPlaying.shared.end()
            await engine.close()
            PlaybackAudioSession.shared.deactivate()
        }
        UIApplication.shared.isIdleTimerDisabled = false
        layer = nil
        snapshot = nil
        qualities = []
        quality = nil
        videoID = nil
        if let localFile {
            localFile.stopAccessingSecurityScopedResource()
            self.localFile = nil
        }
    }

    /// A local file (US-027): Files, the document picker or another app's "Open in". The same
    /// Separator, renderers, Now Playing and PiP as a YouTube video; no history, no quality.
    /// - voicesOnly: a download saved without music: played as it is (pass-through).
    func playFile(_ url: URL, voicesOnly: Bool = false) async {
        await stop(reason: "new file")
        generation += 1
        let token = generation
        error = nil
        resolving = true
        let name = url.deletingPathExtension().lastPathComponent
        title = name
        removeMusic = voicesOnly ? false : AppSettings.shared.removeMusic
        let scoped = url.startAccessingSecurityScopedResource()
        if scoped { localFile = url }
        AppLog.player.info("local tap file=\(url.pathExtension) removeMusic=\(removeMusic) scoped=\(scoped)")
        do {
            let hasVideo = !(try await AVURLAsset(url: url).loadTracks(withMediaType: .video)).isEmpty
            guard token == generation else { return }
            detail = url.pathExtension.uppercased()
            try PlaybackAudioSession.shared.activate()
            let backend = PlaybackServices.shared.playerBackend(models: models)
            let separator = Separator(backend: backend, log: { line in
                AppLog.musicless.info(line.hasPrefix("Window pipeline") ? line + " appState=\(AppActivity.logValue)" : line)
            })
            var output: LocalPlayerEngine.VideoOutput?
            if hasVideo {
                let layer = AVSampleBufferDisplayLayer()
                layer.videoGravity = .resizeAspect
                layer.backgroundColor = UIColor.black.cgColor
                self.layer = layer
                output = LocalPlayerEngine.VideoOutput(renderer: layer.sampleBufferRenderer)
                pip = PictureInPicture(layer: layer, target: self)
            }
            NowPlaying.shared.begin(target: self, title: name, author: String(localized: "On this iPhone"), duration: nil, artwork: nil)
            let engine = LocalPlayerEngine(
                url: url, stage: SeparatorStage(separator: separator), video: output,
                log: { AppLog.player.info($0 + " appState=\(AppActivity.logValue)") },
                onChange: { [weak self] snapshot in Task { @MainActor in self?.changed(snapshot) } })
            self.engine = engine
            if speed != 1 { await engine.setSpeed(speed) }
            resolving = false
            startPolling()
            await engine.start(at: 0, removeMusic: removeMusic, playing: true)
        } catch {
            guard token == generation else { return }
            resolving = false
            self.error = "\(error)"
            AppLog.player.info("local failed error=\(error)")
        }
    }

    /// Watch history (US-022): start, pause and end, as VideoStateController.saveState sends them.
    private func reportHistory(_ previous: PlayerEngine.Snapshot?, _ snapshot: PlayerEngine.Snapshot) {
        guard let videoID, let length = snapshot.duration else { return }
        let event: String?
        if snapshot.status == .ended, previous?.status != .ended {
            event = "end"
        } else if snapshot.status == .playing, !historyStarted {
            historyStarted = true
            event = "start"
        } else if previous?.wantsToPlay == true, !snapshot.wantsToPlay {
            event = "pause"
        } else {
            event = nil
        }
        guard let event else { return }
        let position = event == "end" ? length : snapshot.position
        // Not at the start: the player begins at 0 and would wipe an earlier record.
        if event != "start" { WatchProgress.shared.record(videoID: videoID, position: position, length: length) }
        let history = PlaybackServices.shared.history
        Task { await history.report(videoID: videoID, position: position, length: length, event: event) }
    }

    /// The red bar's own record (WatchProgress) every 15 s of playing, so a killed app keeps most
    /// of it. From the engine's changes and the 250 ms poll (steady playback only polls).
    private func checkpointProgress(_ snapshot: PlayerEngine.Snapshot) {
        guard snapshot.status == .playing, let videoID, let length = snapshot.duration,
              abs(snapshot.position - progressRecordedAt) >= 15 else { return }
        progressRecordedAt = snapshot.position
        WatchProgress.shared.record(videoID: videoID, position: snapshot.position, length: length)
    }

    private func changed(_ snapshot: PlayerEngine.Snapshot) {
        checkpointProgress(snapshot)
        reportHistory(self.snapshot, snapshot)
        self.snapshot = snapshot
        NowPlaying.shared.update(snapshot)
        pip?.invalidate()
        updateIdleTimer()
        if snapshot.status == .playing, let tapAt {
            self.tapAt = nil
            AppLog.player.info("voices tap-to-first-audio ms=\(Int((ContinuousClock.now - tapAt) / .milliseconds(1))) "
                               + "playerMs=\(playerMs) appState=\(AppActivity.logValue)")
        }
    }

    private func startPolling() {
        poll = Task { [weak self] in
            while !Task.isCancelled {
                guard let engine = self?.engine else { return }
                let snapshot = await engine.snapshot()
                self?.snapshot = snapshot
                self?.checkpointProgress(snapshot)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }
}
