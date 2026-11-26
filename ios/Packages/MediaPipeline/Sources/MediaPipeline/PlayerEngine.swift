import AVFoundation
import CoreMedia
import Foundation
import os

/// A fragmented MP4 file on googlevideo: the file plus its init and index ranges from the /player answer.
public struct FMP4Source: Sendable {
    public var file: MediaFile
    public var initRange: ClosedRange<Int64>
    public var indexRange: ClosedRange<Int64>

    public init(file: MediaFile, initRange: ClosedRange<Int64>, indexRange: ClosedRange<Int64>) {
        self.file = file
        self.initRange = initRange
        self.indexRange = indexRange
    }
}

/// The picture: an H.264 file, its fetcher, and the renderer that shows it (a display layer's
/// `sampleBufferRenderer`, so the layer can also feed Picture in Picture later).
///
/// `@unchecked Sendable` because the SDK doesn't mark `AVSampleBufferVideoRenderer` Sendable, though
/// it exists to be fed off the main thread (that is what iOS 17 split it out of the layer for). Once
/// handed to the engine, only the engine's queue touches it; the app keeps just the layer.
public struct VideoInput: @unchecked Sendable {
    public var source: FMP4Source
    public var fetcher: MediaFetcher
    public var renderer: AVSampleBufferVideoRenderer

    public init(source: FMP4Source, fetcher: MediaFetcher, renderer: AVSampleBufferVideoRenderer) {
        self.source = source
        self.fetcher = fetcher
        self.renderer = renderer
    }
}

/// A media 403 the engine hands to the app's recovery (US-017): which track's file, and where on the
/// stream the refused request started and this open's served requests started (ms; -1: none), the
/// inputs of the one-minute wall's signature.
public struct MediaRefusal: Sendable, Equatable {
    public enum Track: String, Sendable { case audio, video }
    public var track: Track
    public var itag: Int
    public var forbiddenMs: Int64
    public var lowestServedMs: Int64
    public var highestServedMs: Int64

    /// For refusals outside the engine (downloads, US-028), which use the same recovery.
    public init(track: Track, itag: Int, forbiddenMs: Int64, lowestServedMs: Int64, highestServedMs: Int64) {
        self.track = track
        self.itag = itag
        self.forbiddenMs = forbiddenMs
        self.lowestServedMs = lowestServedMs
        self.highestServedMs = highestServedMs
    }
}

/// What a recovery's new answer offers for each playing file: the same file at a new URL (a
/// repoint, nothing visible), or, when it has no copy of it, another file to switch to at the
/// playhead (audio: a short hold while the voices restart; video: the picture catches up).
public struct RecoveredFiles: Sendable {
    public enum Track: Sendable {
        case same(MediaFile)
        case replacement(FMP4Source, MediaFetcher)
    }
    public var audio: Track?
    public var video: Track?

    public init(audio: Track?, video: Track?) {
        self.audio = audio
        self.video = video
    }

    /// Both tracks repointed to the same files.
    public init(audio: MediaFile?, video: MediaFile?) {
        self.audio = audio.map(Track.same)
        self.video = video.map(Track.same)
    }
}

/// Plays a YouTube video with only the voices (US-012, US-013; PRD §4.2). Audio: fetch → demux →
/// AAC decode → voice stage (the Separator) → LPCM sample buffers → `AVSampleBufferAudioRenderer`.
/// Video: fetch → demux → H.264 sample buffers (still compressed; the renderer decodes them in
/// hardware) → a display layer's `AVSampleBufferVideoRenderer`. Both renderers hang on one
/// `AVSampleBufferRenderSynchronizer`, which owns the clock; a hold is rate 0, so neither the
/// picture nor the clock can run ahead of the voices (Android's `MusiclessAudioSink`).
///
/// - Hold: rate 0 from a start or seek until the first voices and the target's picture are queued;
///   later, when less than 0.25 s of either is queued and more is coming, debounced 100 ms
///   (`HoldDebounce`). Unlike Android, where ExoPlayer pauses for network buffering on its own, this
///   engine is the only one who can stop the clock, so a slow network holds too (`reason=underrun`).
/// - Bounded look-ahead: a voice chunk is taken from the stage only once the previous one is in the
///   renderer; video is pulled by the renderer's readiness (≈ 1–2 s queued), with one segment
///   prefetched.
/// - Seek (PRD §4.2): flush both renderers and the stage, fetch the target's segments; the picture
///   restarts at the segment's keyframe with the frames before the target marked DoNotDisplay, the
///   voices restart the window ramp at the target. The Remove-music switch restarts the audio only.
/// - Background without PiP: `setVideoActive(false)` stops the video fetch and enqueue (a renderer
///   fed in the background fails); `setVideoActive(true)` flushes it and catches up from the keyframe
///   before the playhead, hiding frames that are already late, while the voices play on.
///
/// The engine owns the stage and closes it.
public actor PlayerEngine {
    public enum HoldReason: String, Sendable { case start, seek, underrun }

    public enum Status: Sendable, Equatable {
        case idle
        case loading
        case holding(HoldReason)
        case playing
        case paused
        case ended
        case failed(String)
    }

    public struct Snapshot: Sendable, Equatable {
        public var status: Status
        public var position: Double
        public var duration: Double?
        /// Voices enqueued in the audio renderer past the playhead.
        public var aheadSeconds: Double
        /// Displayable frames enqueued past the playhead; nil without video.
        public var videoAheadSeconds: Double?
        public var removeMusic: Bool
        public var wantsToPlay: Bool
        public var videoActive: Bool
        /// The playback speed while playing (0.5–2).
        public var speed: Float
    }

    public struct Configuration: Sendable {
        /// A hold starts when less than this is enqueued ahead (of either track) and more is coming.
        public var holdBelow: Double = 0.25
        /// Mutes the audio renderer (tests); the clock runs the same.
        public var muted = false
        /// Period of the `voices position=…` line; nil turns it off.
        public var reportEvery: Duration? = .seconds(10)
        /// Recently read segments kept per file (a seek back or a switch doesn't refetch them).
        public var audioCacheBytes = 16 << 20
        public var videoCacheBytes = 48 << 20
        /// After the background, frames earlier than the playhead plus this are hidden while the
        /// picture catches up.
        public var catchUpLead: Double = 0.1
        /// Seconds the audio file runs late without saying so (encoder priming no edit list
        /// declares): its presentation times move earlier by this much, and what falls before 0 is
        /// dropped. The app sets it for YouTube's AAC (D44); an edit list, where present, adds to it.
        public var audioDelay: Double = 0
        /// Debug (US-017): the files the engine opens refuse (403) every request starting at or past
        /// this stream position, until a recovery repoints them, as a walled pair's links do at 60 s.
        public var syntheticWallSeconds: Double?

        public init() {}
    }

    private enum Lane { case audio, video }

    private static let rate = Int64(PCMSampleBuffers.sampleRate)

    private let queue = DispatchSerialQueue(label: "Musicless-Player", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private var audio: FMP4Source
    private var fetcher: MediaFetcher
    private let stage: VoiceStage
    private var video: VideoInput?
    private let configuration: Configuration
    private let log: @Sendable (String) -> Void
    private let holdLog: @Sendable (String) -> Void
    private let onChange: @Sendable (Snapshot) -> Void
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private var audioCache: SegmentCache
    private var videoCache: SegmentCache

    private var header: FMP4Header?
    private var track: FMP4Track?
    private var format: CMAudioFormatDescription?
    private var duration: Double?

    // Audio position. `epoch` changes on every start, seek, switch and close; older work stops.
    private var epoch = 0
    private var expectedGeneration: Int?
    /// Presentation time of the stage's frame 0 (set by the feed before its first samples).
    private var baseTime: CMTime = .zero
    private var enqueuedEnd: CMTime = .zero
    /// The stage delivered its end-of-stream chunk: nothing more is coming.
    private var streamEnded = false
    private var ended = false
    /// Buffers in the audio renderer not yet played, re-enqueued after an automatic flush.
    private var retained: [CMSampleBuffer] = []
    private var feedTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var waiters: [Lane: CheckedContinuation<Void, Never>] = [:]
    /// Input energy per block of the stage's timeline, so each chunk's line compares the input and
    /// voices levels over the same span.
    private var inputLevels = LevelBlocks()
    private var observers: [any NSObjectProtocol] = []

    // Video position. `videoEpoch` changes on every video restart, background and close.
    private var videoHeader: FMP4Header?
    private var videoTrack: FMP4Track?
    private var videoFormat: CMFormatDescription?
    private var videoEpoch = 0
    private var videoFeedTask: Task<Void, Never>?
    /// End of the last displayable frame enqueued (presentation order).
    private var videoEnd: CMTime = .zero
    private var videoStreamEnded = false
    /// False in the background (no fetch, no enqueue).
    private var videoActive = true
    /// The renderer failed (decoding not permitted); the next activation restarts it.
    private var videoNeedsRestart = false
    /// Catching up after the background: late frames are hidden and don't count as starvation.
    private var videoCatchUp = false

    // Recovery (US-017).
    public typealias Recover = @Sendable (MediaRefusal) async -> RecoveredFiles?
    private let recoverHandler: Recover?
    private var recovering: Task<RecoveredFiles?, Never>?
    /// This open's served media requests: the lowest and highest start on the stream (ms; -1: none).
    private var servedLowMs: Int64 = -1
    private var servedHighMs: Int64 = -1

    // Intent and hold.
    private var speed: Float = 1
    private var wantsToPlay = true
    private var removeMusic = true
    private var debounce = HoldDebounce()
    private var holdReason: HoldReason = .start
    private var holdStart: ContinuousClock.Instant?
    private var failure: String?
    private var opened = false
    private var closed = false
    private var startedAt: ContinuousClock.Instant?
    private var firstAudioLogged = false
    private var lastReport: ContinuousClock.Instant?
    /// What `onChange` last reported (status and the switches).
    private var published: (Status, Bool, Bool, Bool)?

    /// - Parameters:
    ///   - log: engine lines (`voices …`, `video …`); the app sends them to its `Player` category.
    ///   - holdLog: `hold reason=…` lines, in Android's format (its `Musicless` tag).
    ///   - onChange: status changes (start, holds, pause, end, failure), from the engine's queue.
    ///   - recover: a media 403's recovery (US-017): a walk for the same files; nil fails playback.
    public init(audio: FMP4Source, fetcher: MediaFetcher, stage: VoiceStage, video: VideoInput? = nil,
                configuration: Configuration = .init(),
                recover: Recover? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in },
                holdLog: @escaping @Sendable (String) -> Void = { _ in },
                onChange: @escaping @Sendable (Snapshot) -> Void = { _ in }) {
        self.recoverHandler = recover
        self.audio = audio
        self.fetcher = fetcher
        self.stage = stage
        self.video = video
        self.configuration = configuration
        self.log = log
        self.holdLog = holdLog
        self.onChange = onChange
        audioCache = SegmentCache(capacity: configuration.audioCacheBytes)
        videoCache = SegmentCache(capacity: configuration.videoCacheBytes)
    }

    // MARK: Control

    /// Opens the files and starts at `seconds`, holding until the first voices (and picture) are ready.
    public func start(at seconds: Double = 0, removeMusic: Bool = true, playing: Bool = true) async {
        guard !opened, !closed else { return }
        opened = true
        startedAt = .now
        self.removeMusic = removeMusic
        wantsToPlay = playing
        renderer.isMuted = configuration.muted
        // Speed keeps the pitch; the time-domain algorithm is the one Apple describes for speech (US-018).
        renderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.addRenderer(renderer)
        if let video { synchronizer.addRenderer(video.renderer) }
        // Our hold logic decides when the clock runs; the synchronizer's own wait for "sufficient
        // media data" would add an unmeasured delay (DECISIONS D43).
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        observe()
        hold(.start)
        publish()
        do {
            async let openedVideo = Self.open(video)
            let header = try await FMP4Reader.open(fetcher, initRange: audio.initRange, indexRange: audio.indexRange)
            guard let track = header.track(.audio) else { throw AACDecoderError("no audio track") }
            let decoder = try AACDecoder(track: track)
            try await stage.configure(sampleRate: decoder.sampleRate, channels: decoder.channels)
            let videoHeader = try await openedVideo
            if let videoHeader {
                guard let videoTrack = videoHeader.track(.video) else { throw AACDecoderError("no video track") }
                self.videoHeader = videoHeader
                self.videoTrack = videoTrack
                videoFormat = try videoTrack.formatDescription()
                log("video open itag=\(video!.source.file.itag) codec=\(videoTrack.codec) size=\(videoTrack.width)x\(videoTrack.height) "
                    + "timescale=\(videoTrack.timescale) edit=\(videoTrack.editMediaTime) segments=\(videoHeader.index.references.count)")
            }
            self.header = header
            self.track = track
            format = try PCMSampleBuffers.format()
            if let last = header.index.references.last {
                duration = header.index.seconds(last.startTime + UInt64(last.duration))
            }
            log("voices open itag=\(audio.file.itag) codec=\(track.codec) rate=\(Int(decoder.sampleRate)) "
                + "channels=\(decoder.channels) segments=\(header.index.references.count) "
                + "duration=\(Self.format(duration ?? 0)) priming=\(track.editMediaTime) "
                + "delayMs=\(String(format: "%.1f", configuration.audioDelay * 1000)) "
                + "openMs=\(Self.milliseconds(since: startedAt!))")
        } catch {
            fail(error)
            return
        }
        guard !closed else { return }
        if let wall = configuration.syntheticWallSeconds {
            if let header { await armSyntheticWall(fetcher, header: header, at: wall, label: "audio") }
            if let video, let videoHeader { await armSyntheticWall(video.fetcher, header: videoHeader, at: wall, label: "video") }
        }
        outputTask = Task { await self.outputLoop() }
        tickTask = Task { await self.tickLoop() }
        await restart(at: seconds, reason: .start, passThrough: !removeMusic, video: true)
    }

    private static func open(_ video: VideoInput?) async throws -> FMP4Header? {
        guard let video else { return nil }
        return try await FMP4Reader.open(video.fetcher, initRange: video.source.initRange, indexRange: video.source.indexRange)
    }

    public func play() {
        wantsToPlay = true
        if ended { return }
        applyRate()
        publish()
    }

    public func pause() {
        wantsToPlay = false
        applyRate()
        publish()
    }

    /// Restarts both tracks at `seconds` (PRD §4.2), holding until the voices and picture are ready.
    public func seek(to seconds: Double) async {
        guard header != nil, !closed else { return }
        log("voices seek from=\(Self.format(synchronizer.currentTime().seconds)) to=\(Self.format(seconds))")
        await restart(at: seconds, reason: .seek, passThrough: nil, video: true)
    }

    /// The Remove-music switch: pass-through on or off, with a flush of the audio at the current
    /// position. The picture already queued stays valid, so it isn't touched.
    public func setRemoveMusic(_ on: Bool) async {
        guard on != removeMusic else { return }
        removeMusic = on
        guard header != nil, !closed else { return }
        log("voices removeMusic=\(on) at=\(Self.format(synchronizer.currentTime().seconds))")
        await restart(at: synchronizer.currentTime().seconds, reason: .seek, passThrough: !on, video: false)
    }

    /// The quality picker: another H.264 file of the same video on the same renderer. The new file's
    /// header is read first; then the picture restarts at the playhead and catches up as after the
    /// background (the old picture stays on screen meanwhile, a flush keeps it), while the voices play on.
    public func switchVideo(to source: FMP4Source, fetcher: MediaFetcher) async throws {
        guard video != nil, videoHeader != nil, !closed else { return }
        let header = try await FMP4Reader.open(fetcher, initRange: source.initRange, indexRange: source.indexRange)
        guard let track = header.track(.video) else { throw AACDecoderError("no video track") }
        let format = try track.formatDescription()
        guard var input = video, !closed else { return }
        input.source = source
        input.fetcher = fetcher
        video = input
        videoHeader = header
        videoTrack = track
        videoFormat = format
        videoCache = SegmentCache(capacity: configuration.videoCacheBytes)
        log("video switch itag=\(source.file.itag) size=\(track.width)x\(track.height) at=\(Self.format(synchronizer.currentTime().seconds))")
        restartVideo(at: synchronizer.currentTime().seconds, reason: "quality", catchUp: true)
        publish()
    }

    /// Background without PiP: false stops feeding the picture; true catches it up to the playhead.
    public func setVideoActive(_ active: Bool) {
        guard let video, videoHeader != nil, !closed else {
            videoActive = active
            return
        }
        if !active {
            guard videoActive else { return }
            videoActive = false
            videoEpoch += 1
            videoFeedTask?.cancel()
            videoFeedTask = nil
            video.renderer.stopRequestingMediaData()
            resumeWaiter(.video)
            log("video paused (background) at=\(Self.format(synchronizer.currentTime().seconds))")
            updateHold()
        } else {
            guard !videoActive || videoNeedsRestart else { return }
            videoActive = true
            log("video resume at=\(Self.format(synchronizer.currentTime().seconds)) "
                + "requiresFlush=\(video.renderer.requiresFlushToResumeDecoding) status=\(video.renderer.status.rawValue) "
                + "error=\(video.renderer.error.map { "\(($0 as NSError).domain):\(($0 as NSError).code)" } ?? "none")")
            restartVideo(at: synchronizer.currentTime().seconds, reason: "resume", catchUp: true)
        }
        publish()
    }

    public func snapshot() -> Snapshot {
        Snapshot(status: status, position: synchronizer.currentTime().seconds, duration: duration,
                 aheadSeconds: aheadSeconds, videoAheadSeconds: video == nil ? nil : videoAheadSeconds,
                 removeMusic: removeMusic, wantsToPlay: wantsToPlay, videoActive: videoActive, speed: speed)
    }

    /// Stops playback, releases the renderers and closes the stage.
    public func close() async {
        guard !closed else { return }
        if debounce.holding { logHold(end: .now) }
        closed = true
        epoch += 1
        videoEpoch += 1
        feedTask?.cancel()
        videoFeedTask?.cancel()
        tickTask?.cancel()
        synchronizer.rate = 0
        renderer.stopRequestingMediaData()
        video?.renderer.stopRequestingMediaData()
        resumeWaiter(.audio)
        resumeWaiter(.video)
        renderer.flush()
        video?.renderer.flush()
        retained.removeAll()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
        if opened {
            _ = await synchronizer.removeRenderer(renderer, at: .zero)
            if let video { _ = await synchronizer.removeRenderer(video.renderer, at: .zero) }
        }
        await stage.close()  // ends the output loop's wait
        log("voices close")
        publish()
    }

    // MARK: Restart (start, seek, switch)

    private func restart(at seconds: Double, reason: HoldReason, passThrough: Bool?, video withVideo: Bool) async {
        epoch += 1
        let token = epoch
        feedTask?.cancel()
        feedTask = nil
        expectedGeneration = nil
        if debounce.holding && holdStart != nil && reason != .start { logHold(end: .now) }
        let target = max(0, min(seconds, (duration ?? .infinity) - 0.1))
        let time = CMTime(value: Int64((target * Double(Self.rate)).rounded()), timescale: CMTimeScale(Self.rate))
        synchronizer.setRate(0, time: time)
        renderer.flush()
        retained.removeAll()
        baseTime = time
        enqueuedEnd = time
        streamEnded = false
        ended = false
        inputLevels = LevelBlocks()
        if withVideo { restartVideo(at: target, reason: reason.rawValue, catchUp: false) }
        if reason == .start && debounce.holding && holdStart != nil {
            applyRate()  // the start hold began when start() was called: keep its clock
        } else {
            hold(reason)
        }
        publish()
        let generation = await stage.flush(passThrough: passThrough)
        guard token == epoch, !closed else { return }
        await stage.beginHold()
        guard token == epoch, !closed else { return }
        expectedGeneration = generation
        feedTask = Task { await self.feed(from: target, generation: generation, epoch: token) }
    }

    private func restartVideo(at target: Double, reason: String, catchUp: Bool) {
        guard let video, videoHeader != nil else { return }
        videoEpoch += 1
        let token = videoEpoch
        videoFeedTask?.cancel()
        videoFeedTask = nil
        resumeWaiter(.video)
        video.renderer.flush()  // also clears a failure or requiresFlushToResumeDecoding
        videoNeedsRestart = false
        videoEnd = CMTime(value: Int64((target * Double(Self.rate)).rounded()), timescale: CMTimeScale(Self.rate))
        videoStreamEnded = false
        videoCatchUp = catchUp
        guard videoActive else { return }
        videoFeedTask = Task { await self.videoFeed(from: target, reason: reason, epoch: token) }
    }

    // MARK: Audio feed: segments -> AAC -> stage

    private func feed(from target: Double, generation: Int, epoch token: Int) async {
        guard let header, let track else { return }
        let timescale = Double(track.timescale)
        let edit = Double(max(0, track.editMediaTime)) / timescale + configuration.audioDelay
        let first = header.index.seek(to: target + edit)?.index ?? 0
        var nextIndex = first
        var segments = FMP4Reader.segments(fetcher, header: header, from: first, cache: audioCache).makeAsyncIterator()
        defer { segments.cancel() }
        do {
            let decoder = try AACDecoder(track: track)
            let rate = decoder.sampleRate
            var toDrop: Int?
            var sent = false
            while true {
                let next: FMP4Segments.Segment?
                do {
                    next = try await segments.next()
                } catch let refused as MediaRefused {
                    // A routine 403: the app walks for the same file, the fetcher repoints, and the
                    // feed carries on from the segment it was refused.
                    segments.cancel()
                    guard token == epoch, !closed, await recover(refused, track: .audio) else { throw refused }
                    guard token == epoch, !closed else { return }
                    segments = FMP4Reader.segments(fetcher, header: header, from: nextIndex, cache: audioCache).makeAsyncIterator()
                    continue
                }
                guard let segment = next else { break }
                nextIndex = segment.index + 1
                noteServed(segment, index: header.index)
                guard token == epoch, !closed else { return }
                let samples = try FMP4Demuxer.parseSegment(segment.data, track: track)
                var pcm = try decoder.decode(samples)
                if toDrop == nil, let firstSample = samples.first {
                    // Frame 0 of this feed is the segment's first sample; drop what precedes the target.
                    let presentation = Double(firstSample.decodeTime) / timescale - edit
                    let drop = max(0, Int(((target - presentation) * rate).rounded(.up)))
                    toDrop = drop
                    let startSample = Int64((presentation * rate).rounded()) + Int64(drop)
                    baseTime = CMTime(value: startSample, timescale: CMTimeScale(rate))
                    synchronizer.setRate(0, time: baseTime)
                    enqueuedEnd = baseTime
                }
                if let drop = toDrop, drop > 0 {
                    let frames = min(drop, pcm.count / decoder.channels)
                    pcm.removeFirst(frames * decoder.channels)
                    toDrop = drop - frames
                }
                guard !pcm.isEmpty else { continue }
                inputLevels.add(pcm, channels: decoder.channels, scale: Double(Self.rate) / rate)
                sent = true
                await stage.enqueue(pcm, generation: generation)
            }
            guard token == epoch, !closed else { return }
            let tail = try decoder.finish()
            if !tail.isEmpty, sent { await stage.enqueue(tail, generation: generation) }
            await stage.endOfStream(generation: generation)
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if token == epoch, !closed { fail(error) }
        }
    }

    // MARK: Audio output: stage -> renderer

    private func outputLoop() async {
        while !closed {
            guard let chunk = await stage.nextChunk() else { return }
            guard let expected = expectedGeneration, chunk.generation == expected, let format else { continue }
            let token = epoch
            if chunk.isEndOfStream {
                streamEnded = true
                log("voices end-of-stream at=\(Self.format(enqueuedEnd.seconds))")
                updateHold()
                continue
            }
            if chunk.isSilence { log("voices silence frames=\(chunk.frameCount) (separation failed)") }
            let start = baseTime + CMTime(value: chunk.startFrame, timescale: CMTimeScale(Self.rate))
            let span = chunk.startFrame..<(chunk.startFrame + Int64(chunk.frameCount))
            log("voices chunk startS=\(Self.format(start.seconds)) seconds=\(Self.format(Double(chunk.frameCount) / Double(Self.rate))) "
                + "inputDb=\(inputLevels.decibels(span)) voicesDb=\(Self.decibels(chunk.samples)) removeMusic=\(removeMusic)")
            var offset = 0
            while offset < chunk.frameCount {
                while !renderer.isReadyForMoreMediaData && token == epoch && !closed {
                    updateHold()  // about to wait: what is queued may already be enough to play
                    await wait(for: .audio)
                }
                guard token == epoch, !closed else { break }
                let count = min(PCMSampleBuffers.framesPerBuffer, chunk.frameCount - offset)
                let time = start + CMTime(value: Int64(offset), timescale: CMTimeScale(Self.rate))
                do {
                    let buffer = try PCMSampleBuffers.make(chunk.samples, offset: offset, frames: count, at: time, format: format)
                    renderer.enqueue(buffer)
                    retained.append(buffer)
                } catch {
                    fail(error)
                    return
                }
                enqueuedEnd = time + CMTime(value: Int64(count), timescale: CMTimeScale(Self.rate))
                offset += count
                if renderer.status == .failed {
                    fail(renderer.error ?? AACDecoderError("the audio renderer failed"))
                    return
                }
            }
            if token == epoch { updateHold() }
        }
    }

    // MARK: Video feed: segments -> H.264 sample buffers -> renderer

    private func videoFeed(from target: Double, reason: String, epoch token: Int) async {
        guard let video, let header = videoHeader, let track = videoTrack, let format = videoFormat else { return }
        let started = ContinuousClock.now
        let scale = CMTimeScale(track.timescale)
        let edit = max(0, track.editMediaTime)
        let first = header.index.seek(to: target + Double(edit) / Double(track.timescale))?.index ?? 0
        let targetTime = CMTime(value: Int64((target * Double(track.timescale)).rounded()), timescale: scale)
        var nextIndex = first
        var segments = FMP4Reader.segments(video.fetcher, header: header, from: first, cache: videoCache, prefetch: true)
            .makeAsyncIterator()
        defer { segments.cancel() }
        var hidden = 0
        var shown = false
        do {
            while true {
                let next: FMP4Segments.Segment?
                do {
                    next = try await segments.next()
                } catch let refused as MediaRefused {
                    segments.cancel()
                    guard token == videoEpoch, !closed, await recover(refused, track: .video) else { throw refused }
                    guard token == videoEpoch, !closed else { return }
                    segments = FMP4Reader.segments(video.fetcher, header: header, from: nextIndex, cache: videoCache, prefetch: true)
                        .makeAsyncIterator()
                    continue
                }
                guard let segment = next else { break }
                nextIndex = segment.index + 1
                noteServed(segment, index: header.index)
                guard token == videoEpoch, !closed else { return }
                for var sample in try FMP4Demuxer.parseSegment(segment.data, track: track) {
                    while !video.renderer.isReadyForMoreMediaData && token == videoEpoch && !closed {
                        updateHold()
                        await wait(for: .video)
                    }
                    guard token == videoEpoch, !closed else { return }
                    sample.decodeTime -= edit  // the edit list's shift (one frame on YouTube's H.264, D44)
                    let presentation = CMTime(value: sample.presentationTime, timescale: scale)
                    let threshold = videoCatchUp ? synchronizer.currentTime() + CMTime(seconds: configuration.catchUpLead,
                                                                                       preferredTimescale: scale) : targetTime
                    let buffer = try track.sampleBuffer(sample, format: format)
                    if presentation < threshold {
                        FMP4Track.markDoNotDisplay(buffer)
                        hidden += 1
                    }
                    video.renderer.enqueue(buffer)
                    if video.renderer.status == .failed {
                        videoRendererFailed(video.renderer)
                        return
                    }
                    guard presentation >= threshold else { continue }
                    let end = presentation + CMTime(value: Int64(sample.duration), timescale: scale)
                    if end > videoEnd { videoEnd = end }
                    if !shown {
                        shown = true
                        // `at`: the first displayable frame in decode order (B-frames: up to a few frames past the target).
                        log("video first-frame reason=\(reason) ms=\(Self.milliseconds(since: started)) at=\(Self.format(presentation.seconds)) "
                            + "hidden=\(hidden) segment=\(segment.index) bytes=\(segment.data.count)")
                    }
                    if videoCatchUp && videoAheadSeconds >= configuration.holdBelow {
                        videoCatchUp = false
                        log("video caught-up ms=\(Self.milliseconds(since: started)) ahead=\(Self.format(videoAheadSeconds))")
                    }
                }
            }
            guard token == videoEpoch else { return }
            videoStreamEnded = true
            videoCatchUp = false
            updateHold()
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            if token == videoEpoch, !closed { fail(error) }
        }
    }

    /// The renderer refused frames (decoding not permitted, e.g. just before the background): stop
    /// feeding it; the next activation flushes and restarts it. Not a playback failure.
    private func videoRendererFailed(_ renderer: AVSampleBufferVideoRenderer) {
        let error = renderer.error.map { "\(($0 as NSError).domain):\(($0 as NSError).code)" } ?? "none"
        log("video renderer failed error=\(error) requiresFlush=\(renderer.requiresFlushToResumeDecoding)")
        videoEpoch += 1
        videoFeedTask = nil
        videoNeedsRestart = true
        videoCatchUp = true  // don't hold the voices for a picture that can't decode
        updateHold()
    }

    // MARK: Recovery (US-017)

    /// One recovery for the open (the other track awaits the same walk); both tracks' fetchers are
    /// repointed to the new answer's copies of their files. True when `track` may carry on.
    private func recover(_ refused: MediaRefused, track: MediaRefusal.Track) async -> Bool {
        guard let trackFetcher = track == .audio ? fetcher : video?.fetcher else { return false }
        // Refused on a URL the track has already left (another track's recovery repointed it).
        if await trackFetcher.file.url != refused.url { return true }
        guard let recoverHandler else { return false }
        let task: Task<RecoveredFiles?, Never>
        if let recovering {
            task = recovering
        } else {
            let refusal = MediaRefusal(track: track, itag: refused.itag, forbiddenMs: positionMs(track, byte: refused.byteOffset),
                                       lowestServedMs: servedLowMs, highestServedMs: servedHighMs)
            log("voices media403 track=\(track.rawValue) itag=\(refused.itag) forbiddenStartMs=\(refusal.forbiddenMs) "
                + "servedStartMs=\(servedLowMs)..\(servedHighMs) status=\(refused.status)")
            task = Task { await recoverHandler(refusal) }
            recovering = task
        }
        let files = await task.value
        if recovering == task { recovering = nil }
        guard let files, !closed else {
            log("voices recovery failed track=\(track.rawValue) itag=\(refused.itag)")
            return false
        }
        var carriesOn = false
        // Audio: repoint the same file, or switch to the replacement (which restarts the audio feed;
        // the refused feed then sees a new epoch and leaves quietly).
        switch files.audio {
        case .same(let file)?:
            if await repoint(fetcher, to: file) { carriesOn = carriesOn || track == .audio }
        case .replacement(let source, let replacementFetcher)?:
            let stillRefused = await fetcher.file.url == refused.url
            if stillRefused || track == .audio { await switchAudio(to: source, fetcher: replacementFetcher) }
        case nil: break
        }
        if let video {
            switch files.video {
            case .same(let file)?:
                if await repoint(video.fetcher, to: file) { carriesOn = carriesOn || track == .video }
            case .replacement(let source, let replacementFetcher)?:
                let stillRefused = await video.fetcher.file.url == refused.url
                if stillRefused || track == .video { try? await switchVideo(to: source, fetcher: replacementFetcher) }
            case nil: break
            }
        }
        log("wall-swap track=\(track.rawValue) itag=\(refused.itag) repointed=\(carriesOn ? "y" : "n")")
        return carriesOn
    }

    private func repoint(_ target: MediaFetcher, to file: MediaFile) async -> Bool {
        if await target.file.url == file.url { return true }
        do {
            try await target.repoint(to: file)
            return true
        } catch {
            log("voices repoint refused itag=\(file.itag) error=\(error)")
            return false
        }
    }

    /// A recovery found no copy of the playing audio file: open the replacement and restart the
    /// voices at the playhead (a hold, like the Remove-music switch). The picture is untouched.
    private func switchAudio(to source: FMP4Source, fetcher replacement: MediaFetcher) async {
        let position = synchronizer.currentTime().seconds
        do {
            let opened = try await FMP4Reader.open(replacement, initRange: source.initRange, indexRange: source.indexRange)
            guard let newTrack = opened.track(.audio) else { throw AACDecoderError("no audio track") }
            let decoder = try AACDecoder(track: newTrack)
            if let current = track, current.sampleRate != newTrack.sampleRate || current.channels != newTrack.channels {
                try await stage.configure(sampleRate: decoder.sampleRate, channels: decoder.channels)
            }
            guard !closed else { return }
            audio = source
            fetcher = replacement
            header = opened
            track = newTrack
            audioCache = SegmentCache(capacity: configuration.audioCacheBytes)
            log("voices switch-audio itag=\(source.file.itag) at=\(Self.format(position))")
            await restart(at: position, reason: .seek, passThrough: nil, video: false)
        } catch {
            fail(error)
        }
    }

    private func noteServed(_ segment: FMP4Segments.Segment, index: FMP4SegmentIndex) {
        // A request start, or the opening segment that came with the header request (stream 0).
        guard segment.requestStart || (segment.index == 0 && servedLowMs < 0) else { return }
        let ms = Int64(index.seconds(segment.reference.startTime) * 1000)
        servedLowMs = servedLowMs < 0 ? ms : min(servedLowMs, ms)
        servedHighMs = max(servedHighMs, ms)
    }

    /// The stream position (ms) of the segment holding `byte` in `track`'s file.
    private func positionMs(_ track: MediaRefusal.Track, byte: Int64) -> Int64 {
        guard let index = (track == .audio ? header : videoHeader)?.index,
              let reference = index.references.first(where: { $0.bytes.contains(byte) || $0.bytes.lowerBound >= byte }) else { return 0 }
        return Int64(index.seconds(reference.startTime) * 1000)
    }

    private func armSyntheticWall(_ fetcher: MediaFetcher, header: FMP4Header, at seconds: Double, label: String) async {
        guard let reference = header.index.references.first(where: { header.index.seconds($0.startTime) >= seconds }) else { return }
        await fetcher.setSyntheticRefusal(fromByte: reference.bytes.lowerBound)
        log("voices synthetic-wall track=\(label) at=\(Self.format(header.index.seconds(reference.startTime))) byte=\(reference.bytes.lowerBound)")
    }

    // MARK: Renderer readiness

    private func queued(_ lane: Lane) -> any AVQueuedSampleBufferRendering {
        switch lane {
        case .audio: renderer
        case .video: video!.renderer
        }
    }

    private func wait(for lane: Lane) async {
        await withCheckedContinuation { continuation in
            waiters[lane]?.resume()
            waiters[lane] = continuation
            queued(lane).requestMediaDataWhenReady(on: queue) { [weak self] in
                Task { await self?.ready(lane) }
            }
        }
    }

    private func ready(_ lane: Lane) {
        queued(lane).stopRequestingMediaData()
        resumeWaiter(lane)
    }

    private func resumeWaiter(_ lane: Lane) {
        waiters.removeValue(forKey: lane)?.resume()
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVSampleBufferAudioRendererWasFlushedAutomatically, object: renderer,
                                            queue: nil) { [weak self] note in
            let time = (note.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            Task { await self?.rendererFlushedAutomatically(at: time) }
        })
        guard let video else { return }
        observers.append(center.addObserver(forName: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                                            object: video.renderer, queue: nil) { [weak self] _ in
            Task { await self?.videoDecodingChanged() }
        })
        observers.append(center.addObserver(forName: AVSampleBufferVideoRenderer.didFailToDecodeNotification, object: video.renderer,
                                            queue: nil) { [weak self] note in
            let error = (note.userInfo?[AVSampleBufferVideoRenderer.didFailToDecodeNotificationErrorKey] as? NSError)
                .map { "\($0.domain):\($0.code)" } ?? "none"
            self?.log("video decode failed error=\(error)")
        })
    }

    private func videoDecodingChanged() {
        guard let video else { return }
        log("video requiresFlush=\(video.renderer.requiresFlushToResumeDecoding) status=\(video.renderer.status.rawValue) "
            + "active=\(videoActive)")
        if video.renderer.requiresFlushToResumeDecoding { videoNeedsRestart = true }
    }

    /// The audio renderer flushed itself (an output change): put back what it held, in order. A
    /// flush of our own first drops anything the output loop enqueued after the automatic one.
    private func rendererFlushedAutomatically(at time: CMTime?) {
        guard !closed, let time, time.isValid else { return }
        renderer.flush()
        let keep = retained.filter { CMTimeAdd($0.presentationTimeStamp, $0.duration) > time }
        keep.forEach { renderer.enqueue($0) }
        retained = keep
        log("voices renderer flushed automatically at=\(Self.format(time.seconds)) reEnqueued=\(keep.count)")
    }

    // MARK: Hold

    private var aheadSeconds: Double { (enqueuedEnd - synchronizer.currentTime()).seconds }
    private var videoAheadSeconds: Double { (videoEnd - synchronizer.currentTime()).seconds }

    /// Whether the picture can starve the clock: present, in the foreground, not catching up, not ended.
    private var videoCounts: Bool { video != nil && videoActive && !videoCatchUp && !videoStreamEnded }

    private func hold(_ reason: HoldReason) {
        let now = ContinuousClock.now
        holdReason = reason
        holdStart = now
        debounce.set(true, now: now)
        applyRate()
    }

    /// Android's `updateHold`: starved = more is coming and less than `holdBelow` is queued, here
    /// for the voices or the picture.
    private func updateHold() {
        guard !closed, failure == nil, header != nil, expectedGeneration != nil else { return }
        let now = ContinuousClock.now
        let audioStarved = !streamEnded && aheadSeconds < configuration.holdBelow
        let videoStarved = videoCounts && videoAheadSeconds < configuration.holdBelow
        let starved = audioStarved || videoStarved
        if starved && debounce.since == nil && !debounce.holding {
            Task { await stage.beginHold() }
        }
        guard debounce.update(starved: starved, now: now) else { return }
        if debounce.holding {
            holdStart = debounce.since
            holdReason = .underrun
            log("voices underrun audioAhead=\(Self.format(aheadSeconds)) videoAhead=\(video == nil ? "-" : Self.format(videoAheadSeconds))")
        } else {
            logHold(end: now)
            if !firstAudioLogged, let startedAt {
                firstAudioLogged = true
                log("voices first-audio ms=\(Self.milliseconds(since: startedAt)) at=\(Self.format(baseTime.seconds)) "
                    + "ahead=\(Self.format(aheadSeconds)) videoAhead=\(video == nil ? "-" : Self.format(videoAheadSeconds)) "
                    + "sufficient=\(renderer.hasSufficientMediaDataForReliablePlaybackStart)")
            }
        }
        applyRate()
        publish()
    }

    private func logHold(end: ContinuousClock.Instant) {
        guard let start = holdStart else { return }
        holdStart = nil
        let reason = holdReason
        let stage = stage, holdLog = holdLog
        Task {
            let stats = await stage.holdStats()
            let inputEnd = stats.inputReadyAt.map { min($0, end) } ?? end
            holdLog("hold reason=\(reason.rawValue) waitInputMs=\(max(0, Self.milliseconds(start, inputEnd))) "
                    + "queueMs=\(stats.queueMs) waitModelMs=\(stats.waitModelMs) inferMs=\(stats.inferMs) "
                    + "totalMs=\(Self.milliseconds(start, end))")
        }
    }

    /// Playback speed, 0.5–2 (US-018): the synchronizer's rate, so the picture and the voices stay together.
    public func setSpeed(_ value: Float) {
        speed = min(max(value, 0.5), 2)
        log("voices speed=\(speed)")
        applyRate()
    }

    private func applyRate() {
        let target: Float = wantsToPlay && !debounce.holding && failure == nil && !ended && !closed ? speed : 0
        if synchronizer.rate != target { synchronizer.rate = target }
    }

    // MARK: Clock tick

    /// Wakes when starvation could first happen (the playhead can't eat what is queued faster than
    /// real time), every 25 ms while debouncing, and every 250 ms while holding or paused.
    private func tickLoop() async {
        while !closed {
            let delay = tick()
            try? await Task.sleep(for: delay)
        }
    }

    private func tick() -> Duration {
        let now = synchronizer.currentTime()
        if retained.count > 1 {
            retained.removeAll { CMTimeAdd($0.presentationTimeStamp, $0.duration) < now - CMTime(value: 1, timescale: 2) }
        }
        updateHold()
        if streamEnded, !ended, now >= enqueuedEnd {
            ended = true
            applyRate()
            log("voices ended at=\(Self.format(now.seconds))")
            publish()
        }
        if let every = configuration.reportEvery, !debounce.holding, synchronizer.rate > 0,
           lastReport.map({ ContinuousClock.now - $0 >= every }) ?? true {
            lastReport = .now
            // Each renderer's timebase against the synchronizer's clock (US-013): both are slaved to it,
            // so anything but ~0 would mean a renderer presents on a different clock.
            let clock = synchronizer.currentTime()
            let audioClock = (CMTimebaseGetTime(renderer.timebase) - clock).seconds * 1000
            let videoClock = video.map { (CMTimebaseGetTime($0.renderer.timebase) - clock).seconds * 1000 }
            log("voices position=\(Self.format(now.seconds)) ahead=\(Self.format(aheadSeconds)) "
                + "videoAhead=\(video == nil ? "-" : videoActive ? Self.format(videoAheadSeconds) : "off") status=\(status.logValue) "
                + "audioClockMs=\(String(format: "%.2f", audioClock)) videoClockMs=\(videoClock.map { String(format: "%.2f", $0) } ?? "-")")
        }
        if debounce.since != nil && !debounce.holding { return .milliseconds(25) }
        guard synchronizer.rate > 0 else { return .milliseconds(250) }
        var slack = aheadSeconds - configuration.holdBelow
        if videoCounts { slack = min(slack, videoAheadSeconds - configuration.holdBelow) }
        slack /= Double(max(speed, 0.5))  // media seconds go faster than wall seconds above 1×
        return .milliseconds(Int(max(0.025, min(slack, 0.5)) * 1000))
    }

    // MARK: State

    private var status: Status {
        if let failure { return .failed(failure) }
        if closed || !opened { return .idle }
        if ended { return .ended }
        if header == nil { return .loading }
        if !wantsToPlay { return .paused }
        if debounce.holding { return .holding(holdReason) }
        return .playing
    }

    private func publish() {
        let snapshot = snapshot()
        let key = (snapshot.status, snapshot.removeMusic, snapshot.wantsToPlay, snapshot.videoActive)
        if let published, published == key { return }
        published = key
        onChange(snapshot)
    }

    private func fail(_ error: Error) {
        guard failure == nil else { return }
        failure = error is MediaRefused ? "media refused (\(error)); recovery is US-017" : "\(error)"
        log("voices failed error=\(failure!)")
        applyRate()
        publish()
    }

    // MARK: Helpers

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int { milliseconds(start, .now) }

    private static func milliseconds(_ start: ContinuousClock.Instant, _ end: ContinuousClock.Instant) -> Int {
        Int((end - start) / .milliseconds(1))
    }

    static func format(_ seconds: Double) -> String { String(format: "%.2f", seconds) }

    /// RMS level in dBFS of interleaved samples ("-inf" for silence).
    static func decibels(_ samples: [Float]) -> String {
        var sum: Double = 0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return LevelBlocks.decibels(sum: sum, count: samples.count)
    }
}

extension PlayerEngine.Status {
    public var logValue: String {
        switch self {
        case .idle: "idle"
        case .loading: "loading"
        case .holding(let reason): "holding-\(reason.rawValue)"
        case .playing: "playing"
        case .paused: "paused"
        case .ended: "ended"
        case .failed: "failed"
        }
    }
}

/// Sum of squares per block of 4,096 frames on the 44.1 kHz timeline, for level comparisons.
struct LevelBlocks {
    static let block = 4_096
    private var sums: [Double] = []
    private var counts: [Int] = []
    private var frames: Double = 0

    /// Interleaved input at its own rate; `scale` maps its frames to 44.1 kHz frames.
    mutating func add(_ samples: [Float], channels: Int, scale: Double) {
        let count = samples.count / channels
        for frame in 0..<count {
            let index = Int((frames + Double(frame)) * scale) / Self.block
            while sums.count <= index {
                sums.append(0)
                counts.append(0)
            }
            for channel in 0..<channels {
                let sample = Double(samples[frame * channels + channel])
                sums[index] += sample * sample
            }
            counts[index] += channels
        }
        frames += Double(count)
    }

    func decibels(_ span: Range<Int64>) -> String {
        guard !span.isEmpty else { return "-inf" }
        let first = Int(span.lowerBound) / Self.block, last = min(Int(span.upperBound - 1) / Self.block, sums.count - 1)
        guard first <= last else { return "?" }
        return Self.decibels(sum: sums[first...last].reduce(0, +), count: counts[first...last].reduce(0, +))
    }

    static func decibels(sum: Double, count: Int) -> String {
        guard count > 0, sum > 0 else { return "-inf" }
        return String(format: "%.1f", 10 * log10(sum / Double(count)))
    }
}
