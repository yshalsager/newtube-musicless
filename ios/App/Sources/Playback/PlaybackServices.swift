import AVFoundation
import Foundation
import MediaPipeline
import MusiclessCore
import os
import UIKit
import YouTubeEngine

/// What every player shares: one model runtime (sessions load once and are released 120 s after the
/// last player leaves, or on a memory warning when idle), the InnerTube transport and visitor.
@MainActor
final class PlaybackServices {
    static let shared = PlaybackServices()

    private(set) var runtime: ModelRuntime?
    let transport = InnerTubeTransport(log: { AppLog.netPath.info($0) })
    let identity: VisitorIdentity
    /// The source walk (US-015) and what it asks with.
    let walker: SourceWalker
    let sources: PlayerSources
    /// The one-minute wall's memory (US-017); a separate book while a synthetic wall is tested, so
    /// a fake wall never benches a source for real.
    let walls: WallBook
    let syntheticWalls: WallBook
    /// The signature and n solver (US-016) and the player JS it solves with.
    let solver: ChallengeSolver
    let cipher: CipherResolver
    /// Browse-shaped requests (search, channels, feeds) over the TV client, with the same visitor
    /// and, signed in, the account.
    let browse: BrowseClient
    /// Sign-in (US-022): the device-code flow, the account's tokens, and watch history.
    let oauth: OAuthClient
    let tokens: AccountTokens
    let history: HistoryReporter
    private var memoryObserver: (any NSObjectProtocol)?

    private init() {
        let log: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
        let youtube = URL.applicationSupportDirectory.appending(path: "youtube", directoryHint: .isDirectory)
        identity = VisitorIdentity(transport: transport, storeURL: youtube.appending(path: "visitor.json"), log: log)
        walker = SourceWalker(network: { await NetworkWatcher.shared.signature() }, routeStore: youtube.appending(path: "routes.json"),
                              log: log)
        walls = WallBook(storeURL: youtube.appending(path: "walls.json"), log: log)
        syntheticWalls = WallBook(storeURL: youtube.appending(path: "walls-synthetic.json"), log: log)
        sources = PlayerSources(transport: transport, visitor: identity,
                                embed: EmbedIdentityStore(transport: transport, storeURL: youtube.appending(path: "embed.json"), log: log),
                                log: log)
        let players = URL.cachesDirectory.appending(path: "youtube/players", directoryHint: .isDirectory)
        solver = ChallengeSolver(cacheDirectory: players, log: { AppLog.netPath.info($0) })
        cipher = CipherResolver(solver: solver, scripts: PlayerScripts(transport: transport, directory: players))
        let visitor = identity
        oauth = OAuthClient(transport: transport, log: log)
        let tokens = AccountTokens(oauth: oauth)
        self.tokens = tokens
        browse = BrowseClient(transport: transport, visitor: { try? await visitor.current().visitorData },
                              authorization: { await tokens.authorization() }, log: log)
        history = HistoryReporter(transport: transport, sources: sources, tokens: tokens)
        memoryObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppLog.musicless.info("Memory warning")
                let services = PlaybackServices.shared
                if let runtime = services.runtime { Task { await runtime.didReceiveMemoryWarning() } }
                Task { await services.solver.release() }
            }
        }
    }

    /// At launch, in the background: the visitor, then the current player preprocessed for the
    /// solver, so neither lands on the first tap (US-016).
    func warmUp() {
        let identity = identity, cipher = cipher
        Task(priority: .utility) {
            let start = ContinuousClock.now
            guard let playerURL = try? await identity.current().playerURL else { return }
            do {
                try await cipher.warm(playerURL: playerURL)
                AppLog.netPath.info("solver warm-up done ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
            } catch {
                AppLog.netPath.info("solver warm-up failed error=\(error)")
            }
        }
    }

    /// The player's windows first, a download's in the gaps (US-028).
    let modelGate = ModelGate()
    /// The voice models, handed over at launch (downloads need them without a player).
    var models: ModelStore?

    func playerBackend(models: ModelStore) -> GatedBackend {
        GatedBackend(runtime: runtime(models: models), gate: modelGate, lane: .player)
    }

    func downloadBackend() throws -> GatedBackend {
        guard let models else { throw DownloadError(description: "the voice models aren't available") }
        return GatedBackend(runtime: runtime(models: models), gate: modelGate, lane: .download)
    }

    func runtime(models: ModelStore) -> ModelRuntime {
        if let runtime { return runtime }
        let made = ModelRuntime(models: models.modelURLs, awaitModels: { try await models.awaitReady() },
                                log: { AppLog.musicless.info($0) })
        runtime = made
        return made
    }
}

/// Whether the app is in the background, readable from any thread for log lines (`appState=fg|bg`,
/// which the PRD adds to Android's `Window pipeline` line).
enum AppActivity {
    private static let background = OSAllocatedUnfairLock(initialState: false)

    static var logValue: String { background.withLock { $0 } ? "bg" : "fg" }

    static func set(background value: Bool) {
        let changed = background.withLock { state -> Bool in
            defer { state = value }
            return state != value
        }
        if changed { AppLog.player.info("appState=\(value ? "bg" : "fg")") }
    }
}

/// The Separator as the player's voice stage (MediaPipeline doesn't link ONNX Runtime).
struct SeparatorStage: VoiceStage {
    let separator: Separator

    func configure(sampleRate: Double, channels: Int) async throws {
        try await separator.configure(sampleRate: sampleRate, channels: channels)
    }

    func flush(passThrough: Bool?) async -> Int { await separator.flush(passThrough: passThrough) }
    func enqueue(_ samples: [Float], generation: Int) async { await separator.enqueue(samples, generation: generation) }
    func endOfStream(generation: Int) async { await separator.endOfStream(generation: generation) }

    func nextChunk() async -> VoiceChunk? {
        guard let chunk = await separator.nextChunk() else { return nil }
        return VoiceChunk(generation: chunk.generation, startFrame: chunk.startFrame, samples: chunk.voices,
                          isEndOfStream: chunk.isEndOfStream, isSilence: chunk.isSilence)
    }

    func beginHold() async { await separator.beginHold() }

    func holdStats() async -> VoiceHoldStats {
        let stats = await separator.holdStats
        return VoiceHoldStats(inputReadyAt: stats.inputReadyAt, queueMs: stats.queueMs,
                              waitModelMs: stats.waitModelMs, inferMs: stats.inferMs)
    }

    func close() async { await separator.close() }
}

/// A video's files as the engine needs them, from one VISIONOS `/player` request (the source walk
/// that tries other clients is US-015): the AAC file and, unless audio only, the H.264 file.
struct ResolvedMedia: Sendable {
    var videoID: String
    var title: String
    var author: String
    var audio: FMP4Source
    var audioMime: String
    var video: FMP4Source?
    /// `1080p60 avc1.640028`, for the screen and the log.
    var videoLabel: String?
    /// Every H.264 quality the answer offers (the quality picker), best first; `video` is one of them.
    var videoOptions: [VideoOption]
    /// The best Opus file (WebM), the sync check's reference: Opus states its encoder delay.
    var opus: MediaFile?
    /// The smallest VP9 file (WebM): the sync check's cross-check of the video timeline.
    var vp9: MediaFile?
    /// Seconds the AAC runs late without declaring it (`YouTubeAudio.delay`), for the engine.
    var audioDelay: Double
    /// The largest thumbnail, for Now Playing.
    var thumbnail: URL?
    /// The source that served it (the walk's winner), and the visitor its request carried (nil for
    /// WEB_EMBED's embed identity), which the wall rule blames.
    var client: String
    var visitor: String?
    /// The itags playing, for a recovery's repoint.
    var audioItag: Int
    var videoItag: Int?
    var playerMs: Int
    /// `videoDetails.lengthSeconds`, for resuming before the engine knows the duration.
    var lengthSeconds: Double? = nil
}

/// One H.264 quality of a video, for the quality picker.
struct VideoOption: Identifiable, Hashable, Sendable {
    var id: Int { itag }
    var itag: Int
    /// `1080p60`, `720p`, …
    var label: String
    var source: FMP4Source

    static func == (lhs: VideoOption, rhs: VideoOption) -> Bool { lhs.itag == rhs.itag }
    func hash(into hasher: inout Hasher) { hasher.combine(itag) }

    /// The avc1 files the engine can play (≤ 1080p, ≤ 60 fps, with ranges), best first, one per label
    /// (the higher bitrate wins), the same rules as `FormatSelector`.
    static func options(_ formats: [PlayerAnswer.Format], source: (PlayerAnswer.Format) -> FMP4Source?) -> [VideoOption] {
        let playable = formats.filter {
            $0.container == "video/mp4" && $0.codecs.hasPrefix("avc1") && ($0.shortSide ?? .max) <= FormatSelector.maxAVCShortSide
                && ($0.fps ?? 30) <= 60
        }
        .sorted { ($0.shortSide ?? 0, $0.fps ?? 0, $0.bitrate ?? 0) > ($1.shortSide ?? 0, $1.fps ?? 0, $1.bitrate ?? 0) }
        var seen = Set<String>()
        return playable.compactMap { format in
            let fps = format.fps ?? 30
            let label = "\(format.shortSide ?? 0)p" + (fps > 30 ? "\(fps)" : "")
            guard !seen.contains(label), let file = source(format) else { return nil }
            seen.insert(label)
            return VideoOption(itag: format.itag, label: label, source: file)
        }
    }
}

/// YouTube's AAC-LC at 44.1 kHz runs 38.9 ms later than its Opus for the same audio, which no edit
/// list or gapless tag declares: measured by cross-correlating the two decodes of 5 videos (4 at
/// 38.9 ms, an older upload at 33.9 ms) and by a sync test's beeps (39.0 ms). The engine moves the
/// AAC earlier by this much so it lands on the timeline Opus states (DECISIONS D44). Android doesn't.
enum YouTubeAudio {
    static let aacDelay = 0.0389

    static func delay(codecs: String, sampleRate: Int?) -> Double {
        codecs == "mp4a.40.2" && sampleRate == 44_100 ? aacDelay : 0
    }
}

/// What a playing video's recovery blames and repoints: the source that served the files, the
/// visitor its request carried, and the itags playing (the quality picker changes the video's).
actor PlayingFiles {
    struct Snapshot: Sendable {
        var client: String
        var visitor: String?
        var audio: MediaFile
        var video: MediaFile?
    }
    private var state: Snapshot

    init(_ media: ResolvedMedia) {
        state = Snapshot(client: media.client, visitor: media.visitor, audio: media.audio.file, video: media.video?.file)
    }

    func snapshot() -> Snapshot { state }
    func served(by client: String, visitor: String?, audio: MediaFile?, video: MediaFile?) {
        state.client = client
        state.visitor = visitor
        if let audio { state.audio = audio }
        if let video { state.video = video }
    }
    func video(_ file: MediaFile) { state.video = file }
}

struct ResolveError: Error, CustomStringConvertible {
    let description: String
}

enum VideoResolver {
    /// Walks the sources (US-015), opens a ciphered winner (US-016), and picks the pair to play.
    /// Settings' quality choices, read on the main actor.
    struct Quality: Sendable {
        var maxShortSide: Int
        var prefer60fps: Bool

        @MainActor static var current: Quality {
            Quality(maxShortSide: AppSettings.shared.maxQuality.rawValue, prefer60fps: AppSettings.shared.prefer60fps)
        }
    }

    @MainActor
    static func media(for videoID: String, withVideo: Bool, synthetic: Bool = false) async throws -> ResolvedMedia {
        let services = PlaybackServices.shared
        let quality = Quality.current
        let sources = services.sources
        let start = ContinuousClock.now
        let visitor = try? await services.identity.current().visitorData
        // Sources walled for this visitor go last (US-017), in the order that asks ANDROID_VR late.
        let plan = await (synthetic ? services.syntheticWalls : services.walls).plan(videoID: videoID, recovery: false, appVisitor: visitor)
        // Signed in: the signed-in lane, the account on the account route only (FR-17).
        let account = await services.tokens.authorization()
        var context = SourcePlanner.Context(lane: account == nil ? .signedOut : .signedIn)
        context.benched = plan.benched
        context.vodVrLate = !plan.benched.isEmpty
        let walk = await services.walker.walk(videoID: videoID, context: context) { client, budget in
            await sources.attempt(client, videoID: videoID, budget: budget,
                                  authorization: client == SourcePlanner.accountRoute ? account : nil)
        }
        if account != nil, walk.client == SourcePlanner.accountRoute, let answer = walk.answer {
            await services.history.noteAccountAnswer(videoID: videoID,
                                                     tracking: WatchHistory.Tracking(videostatsURL: answer.videostatsPlaybackURL,
                                                                                     cpn: answer.requestCPN ?? ""))
        }
        let walkMs = Int((ContinuousClock.now - start) / .milliseconds(1))
        AppLog.netPath.info("player-walk video=\(videoID) asked=\(walk.asked.map(\.id)) winner=\(walk.client?.id ?? "none") "
                            + "playable=\(walk.playable ? "y" : "n") ms=\(walkMs)" + (walk.fromCircuit ? " circuit=y" : ""))
        guard var answer = walk.answer else {
            throw ResolveError(description: "couldn't reach YouTube (\(walk.markers.last ?? "no answer"))")
        }
        guard walk.playable else {
            let reason = answer.playability.text ?? answer.playability.status
            throw ResolveError(description: "\(walk.client?.id ?? "?"): \(answer.kind.logValue) \(reason)")
        }
        guard !answer.isLive else { throw ResolveError(description: "live streams don't play yet") }
        let solveStart = ContinuousClock.now
        answer = try await services.cipher.resolve(answer, playerURL: try await services.identity.current().playerURL)
        let solveMs = Int((ContinuousClock.now - solveStart) / .milliseconds(1))
        if solveMs > 1 { AppLog.netPath.info("player-sig video=\(videoID) client=\(walk.client?.id ?? "?") ms=\(solveMs)") }
        let selection = FormatSelector.select(answer, maxShortSide: quality.maxShortSide, prefer60fps: quality.prefer60fps)
        guard let audioFormat = selection.audio, let audio = source(audioFormat) else {
            throw ResolveError(description: "no AAC file with ranges in the answer")
        }
        var video: FMP4Source?, label: String?
        var options: [VideoOption] = []
        if withVideo {
            guard let videoFormat = selection.video, let picture = source(videoFormat) else {
                throw ResolveError(description: "no H.264 file with ranges in the answer")
            }
            video = picture
            label = "\(videoFormat.shortSide ?? 0)p\(videoFormat.fps ?? 30) \(videoFormat.codecs)"
            options = VideoOption.options(answer.adaptiveFormats, source: source)
        }
        // Several audio tracks (dubs): which one plays, in the log (the original, FormatSelector).
        let tracks = Set(answer.adaptiveFormats.filter(\.isAudio).compactMap(\.audioTrackID))
        if tracks.count > 1 {
            AppLog.netPath.info("audio-track video=\(videoID) chosen=\(audioFormat.audioTrackID ?? "none") "
                                + "original=\(audioFormat.isOriginalAudio ? "y" : "n") tracks=\(tracks.sorted().joined(separator: ","))")
        }
        let opus = FormatSelector.originalTrack(answer.adaptiveFormats
            .filter { $0.container == "audio/webm" && $0.codecs == "opus" && $0.url != nil && $0.contentLength != nil })
            .max { ($0.bitrate ?? 0) < ($1.bitrate ?? 0) }
            .flatMap { format in URL(string: format.url!).map {
                MediaFile(itag: format.itag, lastModified: format.lastModified, contentLength: format.contentLength!, url: $0)
            } }
        let vp9 = answer.adaptiveFormats
            .filter { $0.container == "video/webm" && $0.codecs.hasPrefix("vp9") && $0.url != nil && $0.contentLength != nil }
            .min { ($0.shortSide ?? .max) < ($1.shortSide ?? .max) }
            .flatMap { format in URL(string: format.url!).map {
                MediaFile(itag: format.itag, lastModified: format.lastModified, contentLength: format.contentLength!, url: $0)
            } }
        return ResolvedMedia(videoID: videoID, title: answer.details?.title ?? videoID, author: answer.details?.author ?? "",
                             audio: audio, audioMime: audioFormat.mimeType, video: video, videoLabel: label,
                             videoOptions: options, opus: opus, vp9: vp9,
                             audioDelay: YouTubeAudio.delay(codecs: audioFormat.codecs, sampleRate: audioFormat.audioSampleRate),
                             thumbnail: answer.details?.thumbnails.max { ($0.width ?? 0) < ($1.width ?? 0) }.flatMap { URL(string: $0.url) },
                             client: walk.client?.id ?? "?",
                             visitor: walk.client?.isEmbedded == true ? nil : visitor,
                             audioItag: audioFormat.itag, videoItag: withVideo ? selection.video?.itag : nil,
                             playerMs: Int((ContinuousClock.now - start) / .milliseconds(1)),
                             lengthSeconds: answer.details?.lengthSeconds.map(Double.init))
    }

    /// A media 403's recovery (US-017; LANES §2.3, HANDOFF §34): the wall rule reads the refusal,
    /// the source is blamed (the account route's record, the wall memory, a visitor re-roll for
    /// VISIONOS or ANDROID_VR), a recovery walk asks it last, and the new answer's copies of the
    /// playing files come back for a repoint. Nil when no source serves the same files.
    static func recover(videoID: String, playing: PlayingFiles, refusal: MediaRefusal, synthetic: Bool) async -> RecoveredFiles? {
        let quality = await Quality.current
        let services = await PlaybackServices.shared
        let start = ContinuousClock.now
        let walls = synthetic ? services.syntheticWalls : services.walls
        let current = await playing.snapshot()
        guard let suspect = SourcePlanner.baseOrder.first(where: { $0.id == current.client }) else { return nil }
        // A synthetic wall is no evidence about the account route on this network.
        if !synthetic { await services.walker.noteMediaRefused(videoID: videoID, client: suspect) }
        let verdict = await walls.noteMedia403(videoID: videoID, client: suspect, visitor: current.visitor,
                                               forbiddenMs: refusal.forbiddenMs, lowestServedMs: refusal.lowestServedMs,
                                               highestServedMs: refusal.highestServedMs)
        if verdict.rerollWanted, await walls.spendReroll(videoID: videoID) {
            _ = try? await services.identity.reroll()
        }
        let visitor = try? await services.identity.current().visitorData
        let plan = await walls.plan(videoID: videoID, recovery: true, appVisitor: visitor)
        let account = await services.tokens.authorization()
        var context = SourcePlanner.Context(lane: account == nil ? .signedOut : .signedIn, recoverySuspect: suspect)
        context.benched = plan.benched
        context.refreshed = plan.refreshed
        context.vodVrLate = true
        let sources = services.sources
        let walk = await services.walker.walk(videoID: videoID, context: context) { client, budget in
            await sources.attempt(client, videoID: videoID, budget: budget,
                                  authorization: client == SourcePlanner.accountRoute ? account : nil)
        }
        guard walk.playable, var answer = walk.answer, let winner = walk.client else {
            AppLog.netPath.info("wall-swap video=\(videoID) from=\(suspect.id) failed asked=\(walk.asked.map(\.id))")
            return nil
        }
        guard let opened = try? await services.cipher.resolve(answer, playerURL: try? await services.identity.current().playerURL) else {
            AppLog.netPath.info("wall-swap video=\(videoID) from=\(suspect.id) to=\(winner.id) failed=solve")
            return nil
        }
        answer = opened
        // The same file: itag, lmt and length (an answer can hold two itag-140 files, one with DRC).
        func file(_ playing: MediaFile?) -> MediaFile? {
            guard let playing else { return nil }
            for format in answer.adaptiveFormats where format.itag == playing.itag {
                guard let address = format.url, let url = URL(string: address), let length = format.contentLength else { continue }
                let candidate = MediaFile(itag: format.itag, lastModified: format.lastModified, contentLength: length, url: url)
                if candidate.isSameFile(as: playing) { return candidate }
            }
            return nil
        }
        // No copy of a playing file: switch that track to the answer's own choice (the same itag in
        // another encode first, for the picture), at the playhead.
        let selection = FormatSelector.select(answer, maxShortSide: quality.maxShortSide, prefer60fps: quality.prefer60fps)
        func replacement(_ format: PlayerAnswer.Format?) -> RecoveredFiles.Track? {
            guard let format, let source = source(format) else { return nil }
            return .replacement(source, MediaFetcher(file: source.file, log: { AppLog.netPath.info($0) }))
        }
        let audioSame = file(current.audio), videoSame = file(current.video)
        let audio: RecoveredFiles.Track? = audioSame.map(RecoveredFiles.Track.same) ?? replacement(selection.audio)
        var video: RecoveredFiles.Track?
        if let playingVideo = current.video {
            video = videoSame.map(RecoveredFiles.Track.same)
                ?? replacement(answer.adaptiveFormats.first { $0.itag == playingVideo.itag && $0.url != nil } ?? selection.video)
        }
        func describe(_ track: RecoveredFiles.Track?) -> String {
            switch track {
            case .same(let file)?: "same:\(file.itag)"
            case .replacement(let source, _)?: "switch:\(source.file.itag)"
            case nil: "missing"
            }
        }
        func newFile(_ track: RecoveredFiles.Track?) -> MediaFile? {
            switch track {
            case .same(let file)?: file
            case .replacement(let source, _)?: source.file
            case nil: nil
            }
        }
        await playing.served(by: winner.id, visitor: winner.isEmbedded ? nil : visitor, audio: newFile(audio), video: newFile(video))
        AppLog.netPath.info("wall-swap video=\(videoID) from=\(suspect.id) to=\(winner.id) signature=\(verdict.signature.rawValue) "
                            + "asked=\(walk.asked.map(\.id)) audio=\(describe(audio)) video=\(current.video == nil ? "none" : describe(video)) "
                            + "ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
        return RecoveredFiles(audio: audio, video: video)
    }

    private static func source(_ format: PlayerAnswer.Format) -> FMP4Source? {
        guard let address = format.url, let url = URL(string: address), let length = format.contentLength,
              let initRange = format.initRange, let indexRange = format.indexRange else { return nil }
        return FMP4Source(file: MediaFile(itag: format.itag, lastModified: format.lastModified, contentLength: length, url: url),
                          initRange: initRange.start...initRange.end, indexRange: indexRange.start...indexRange.end)
    }
}

/// The audio session (PRD §4.5): `.playback` / `.moviePlayback`, so voices keep playing with the
/// screen locked (`UIBackgroundModes: audio`). A call or another app's audio pauses the player and
/// resumes it when iOS says so; unplugging headphones pauses it.
@MainActor
final class PlaybackAudioSession {
    static let shared = PlaybackAudioSession()

    /// Called on interruptions and route changes: false = pause, true = resume.
    var onPlayChange: ((Bool) -> Void)?
    private var observers: [any NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt).map(AVAudioSession.InterruptionOptions.init)
            MainActor.assumeIsolated { PlaybackAudioSession.shared.interrupted(type, options: options) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated { PlaybackAudioSession.shared.routeChanged(reason) }
        })
    }

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
        AppLog.player.info("audio session active rate=\(Int(session.sampleRate)) ioBufferMs=\(Int(session.ioBufferDuration * 1000)) "
                           + "route=\(session.currentRoute.outputs.map(\.portType.rawValue).joined(separator: "+"))")
    }

    func deactivate() {
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func interrupted(_ type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions?) {
        switch type {
        case .began:
            AppLog.player.info("audio interruption began")
            onPlayChange?(false)
        case .ended:
            let resume = options?.contains(.shouldResume) == true
            AppLog.player.info("audio interruption ended resume=\(resume)")
            if resume { onPlayChange?(true) }
        default:
            break
        }
    }

    private func routeChanged(_ reason: AVAudioSession.RouteChangeReason?) {
        guard reason == .oldDeviceUnavailable else { return }
        AppLog.player.info("audio route lost the output device; pausing")
        onPlayChange?(false)
    }
}
