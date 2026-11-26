import AVFoundation
import CoreMedia
import Foundation

/// What the app's player drives: the YouTube engine (`PlayerEngine`) or a local file's
/// (`LocalPlayerEngine`). Quality switching is the YouTube engine's own.
public protocol PlaybackEngine: Actor {
    func start(at seconds: Double, removeMusic: Bool, playing: Bool) async
    func play()
    func pause()
    func seek(to seconds: Double) async
    func setRemoveMusic(_ on: Bool) async
    func setSpeed(_ value: Float)
    func setVideoActive(_ active: Bool)
    func snapshot() -> PlayerEngine.Snapshot
    func close() async
}

extension PlayerEngine: PlaybackEngine {}

/// A local file with the music removed (US-027; Android's d074c0c6: local files get music removal
/// too). `AVAssetReader` decodes the audio to interleaved Float32 at 44.1 kHz stereo for the same
/// voice stage, and the picture (decoded by the reader, so a seek lands on its frame) for the same
/// display layer; one synchronizer on the voices' clock, the YouTube engine's hold rule (less than
/// 0.25 s queued while more is coming holds the clock, debounced 100 ms) and the same snapshot.
public actor LocalPlayerEngine: PlaybackEngine {
    private let queue = DispatchSerialQueue(label: "Musicless-LocalPlayer", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    static let rate = Int64(PCMSampleBuffers.sampleRate)
    static let holdBelow = 0.25
    static var audioSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        AVSampleRateKey: Double(PCMSampleBuffers.sampleRate), AVNumberOfChannelsKey: 2,
    ] }

    private let url: URL
    private let stage: VoiceStage
    private let videoRenderer: AVSampleBufferVideoRenderer?
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let log: @Sendable (String) -> Void
    private let onChange: @Sendable (PlayerEngine.Snapshot) -> Void

    private var asset: AVURLAsset?
    private var audioTrack: AVAssetTrack?
    private var videoTrack: AVAssetTrack?
    private var duration: Double?
    private var format: CMAudioFormatDescription?
    private var removeMusic = true
    private var wantsToPlay = true
    private var speed: Float = 1
    private var debounce = HoldDebounce()
    private var holdReason: PlayerEngine.HoldReason = .start
    private var opened = false
    private var ended = false
    private var streamEnded = false
    private var videoEnded = false
    private var videoActive = true
    private var failure: String?
    private var closed = false
    private var epoch = 0
    private var generation = 0
    private var baseTime = CMTime.zero
    private var enqueuedEnd = CMTime.zero
    private var videoEnqueuedEnd = CMTime.zero
    private var feedTask: Task<Void, Never>?
    private var videoTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private enum Lane { case audio, video }
    private var waiters: [Lane: CheckedContinuation<Void, Never>] = [:]
    private var lastPublished: PlayerEngine.Snapshot?
    private var videoFrames = 0

    /// The display layer's renderer, handed to the engine. `@unchecked Sendable` as `VideoInput`:
    /// the layer keeps it for display, and only this engine's queue enqueues to it.
    public struct VideoOutput: @unchecked Sendable {
        let renderer: AVSampleBufferVideoRenderer
        public init(renderer: AVSampleBufferVideoRenderer) { self.renderer = renderer }
    }

    /// - video: nil plays the voices alone (an audio file).
    public init(url: URL, stage: VoiceStage, video: VideoOutput?,
                log: @escaping @Sendable (String) -> Void = { _ in },
                onChange: @escaping @Sendable (PlayerEngine.Snapshot) -> Void = { _ in }) {
        self.url = url
        self.stage = stage
        self.videoRenderer = video?.renderer
        self.log = log
        self.onChange = onChange
    }

    // MARK: Control

    public func start(at seconds: Double = 0, removeMusic: Bool = true, playing: Bool = true) async {
        self.removeMusic = removeMusic
        wantsToPlay = playing
        let started = ContinuousClock.now
        do {
            let asset = AVURLAsset(url: url)
            self.asset = asset
            audioTrack = try await asset.loadTracks(withMediaType: .audio).first
            videoTrack = videoRenderer == nil ? nil : try await asset.loadTracks(withMediaType: .video).first
            guard audioTrack != nil else { throw AACDecoderError("the file has no audio track") }
            duration = try await asset.load(.duration).seconds
            format = try PCMSampleBuffers.format()
            try await stage.configure(sampleRate: Double(Self.rate), channels: 2)
        } catch {
            fail(error)
            return
        }
        guard !closed else { return }
        renderer.audioTimePitchAlgorithm = .timeDomain
        synchronizer.addRenderer(renderer)
        if let videoRenderer, videoTrack != nil { synchronizer.addRenderer(videoRenderer) }
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        opened = true
        log("local open file=\(url.pathExtension) duration=\(Self.format(duration ?? 0)) video=\(videoTrack == nil ? "n" : "y") "
            + "openMs=\(Int((ContinuousClock.now - started) / .milliseconds(1)))")
        outputTask = Task { await self.outputLoop() }
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                await self?.tick()
            }
        }
        await restart(at: seconds, reason: .start)
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

    public func seek(to seconds: Double) async {
        guard opened else { return }
        await restart(at: seconds, reason: .seek)
    }

    public func setRemoveMusic(_ on: Bool) async {
        guard on != removeMusic else { return }
        removeMusic = on
        log("local remove-music=\(on)")
        guard opened else { return }
        await restart(at: synchronizer.currentTime().seconds, reason: .seek)
    }

    public func setSpeed(_ value: Float) {
        speed = min(max(value, 0.5), 2)
        applyRate()
        publish()
    }

    /// In the background without PiP: stop decoding pictures; back: catch up at the playhead.
    public func setVideoActive(_ active: Bool) {
        guard active != videoActive else { return }
        videoActive = active
        guard let videoRenderer, videoTrack != nil, opened else { return }
        videoTask?.cancel()
        videoTask = nil
        if active {
            videoRenderer.flush()
            let now = synchronizer.currentTime()
            videoEnqueuedEnd = now
            videoEnded = false
            let token = epoch
            videoTask = Task { await self.videoFeed(from: now, epoch: token) }
        }
        log("local video active=\(active)")
    }

    public func snapshot() -> PlayerEngine.Snapshot {
        let now = synchronizer.currentTime()
        let status: PlayerEngine.Status
        if let failure {
            status = .failed(failure)
        } else if !opened {
            status = .loading
        } else if ended {
            status = .ended
        } else if debounce.holding {
            status = .holding(holdReason)
        } else {
            status = wantsToPlay ? .playing : .paused
        }
        return PlayerEngine.Snapshot(status: status, position: max(0, now.seconds), duration: duration,
                                     aheadSeconds: max(0, (enqueuedEnd - now).seconds),
                                     videoAheadSeconds: videoTrack == nil ? nil : max(0, (videoEnqueuedEnd - now).seconds),
                                     removeMusic: removeMusic, wantsToPlay: wantsToPlay, videoActive: videoActive, speed: speed)
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        epoch += 1
        feedTask?.cancel()
        videoTask?.cancel()
        tickTask?.cancel()
        synchronizer.rate = 0
        renderer.stopRequestingMediaData()
        videoRenderer?.stopRequestingMediaData()
        for continuation in waiters.values { continuation.resume() }
        waiters = [:]
        renderer.flush()
        videoRenderer?.flush()
        await stage.close()
        outputTask?.cancel()
        log("local close")
    }

    // MARK: Restart (start, seek, Remove music)

    private func restart(at seconds: Double, reason: PlayerEngine.HoldReason) async {
        epoch += 1
        let token = epoch
        feedTask?.cancel()
        videoTask?.cancel()
        let target = max(0, min(seconds, (duration ?? .infinity) - 0.1))
        let time = CMTime(seconds: target, preferredTimescale: CMTimeScale(Self.rate))
        synchronizer.setRate(0, time: time)
        renderer.flush()
        videoRenderer?.flush()
        baseTime = time
        enqueuedEnd = time
        videoEnqueuedEnd = time
        streamEnded = false
        videoEnded = false
        ended = false
        holdReason = reason
        // A restart holds until the voices (and picture) are queued: releasing it sets the rate.
        debounce = HoldDebounce()
        _ = debounce.update(starved: true, now: .now - .seconds(1))
        _ = debounce.update(starved: true, now: .now)
        generation = await stage.flush(passThrough: !removeMusic)
        guard token == epoch, !closed else { return }
        let generation = generation
        feedTask = Task { await self.audioFeed(from: time, generation: generation, epoch: token) }
        if videoTrack != nil, videoActive {
            videoTask = Task { await self.videoFeed(from: time, epoch: token) }
        }
        log("local restart reason=\(reason.rawValue) at=\(Self.format(target)) removeMusic=\(removeMusic)")
        publish()
    }

    // MARK: Audio: file -> stage

    private func audioFeed(from start: CMTime, generation: Int, epoch token: Int) async {
        guard let asset, let audioTrack else { return }
        do {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: start, end: .positiveInfinity)
            let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: Self.audioSettings)
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? AACDecoderError("the audio reader didn't start") }
            defer { reader.cancelReading() }
            var trim: Int64?
            while token == epoch, !closed, !Task.isCancelled {
                guard let buffer = output.copyNextSampleBuffer() else { break }
                var samples = Self.floats(buffer)
                // The reader starts on a packet boundary: drop what comes before the target.
                if trim == nil {
                    let early = (start - buffer.presentationTimeStamp).seconds
                    trim = early > 0 ? Int64(early * Double(Self.rate)) : 0
                }
                if let frames = trim, frames > 0 {
                    let drop = min(Int(frames) * 2, samples.count)
                    samples.removeFirst(drop)
                    trim = frames - Int64(drop / 2)
                }
                guard !samples.isEmpty else { continue }
                await stage.enqueue(samples, generation: generation)
            }
            if reader.status == .failed { throw reader.error ?? AACDecoderError("the audio reader failed") }
            guard token == epoch, !closed else { return }
            await stage.endOfStream(generation: generation)
        } catch {
            if token == epoch, !closed { fail(error) }
        }
    }

    static func floats(_ buffer: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        _ = samples.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        return samples
    }

    // MARK: Audio: stage -> renderer

    private func outputLoop() async {
        while !closed {
            guard let chunk = await stage.nextChunk() else { return }
            guard chunk.generation == generation, let format else { continue }
            let token = epoch
            if chunk.isEndOfStream {
                streamEnded = true
                tick()
                continue
            }
            if chunk.isSilence { log("local silence frames=\(chunk.frameCount) (separation failed)") }
            let start = baseTime + CMTime(value: chunk.startFrame, timescale: CMTimeScale(Self.rate))
            var offset = 0
            while offset < chunk.frameCount, token == epoch, !closed {
                while !renderer.isReadyForMoreMediaData, token == epoch, !closed {
                    tick()
                    await wait(for: .audio)
                }
                guard token == epoch, !closed else { break }
                let count = min(PCMSampleBuffers.framesPerBuffer, chunk.frameCount - offset)
                let time = start + CMTime(value: Int64(offset), timescale: CMTimeScale(Self.rate))
                do {
                    renderer.enqueue(try PCMSampleBuffers.make(chunk.samples, offset: offset, frames: count, at: time, format: format))
                } catch {
                    fail(error)
                    return
                }
                enqueuedEnd = time + CMTime(value: Int64(count), timescale: CMTimeScale(Self.rate))
                offset += count
            }
            if token == epoch { tick() }
        }
    }

    // MARK: Video: file -> display layer

    private func videoFeed(from start: CMTime, epoch token: Int) async {
        guard let asset, let videoTrack, let videoRenderer else { return }
        videoFrames = 0
        do {
            let reader = try AVAssetReader(asset: asset)
            reader.timeRange = CMTimeRange(start: start, end: .positiveInfinity)
            // IOSurface-backed frames: what the display layer composites.
            let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? AACDecoderError("the video reader didn't start") }
            defer { reader.cancelReading() }
            while token == epoch, !closed, !Task.isCancelled, videoActive {
                while !videoRenderer.isReadyForMoreMediaData, token == epoch, !closed {
                    await wait(for: .video)
                }
                guard token == epoch, !closed, let buffer = output.copyNextSampleBuffer() else { break }
                videoRenderer.enqueue(buffer)
                videoFrames += 1
                if videoFrames == 1 {
                    log("local first-frame at=\(Self.format(buffer.presentationTimeStamp.seconds)) status=\(videoRenderer.status.rawValue)")
                }
                videoEnqueuedEnd = buffer.presentationTimeStamp + (buffer.duration.isValid ? buffer.duration : .zero)
            }
            if token == epoch, reader.status == .completed { videoEnded = true }
        } catch {
            log("local video failed error=\(error)")
            if token == epoch { videoEnded = true }
        }
    }

    // MARK: Clock

    private func tick() {
        guard opened, !closed else { return }
        let now = synchronizer.currentTime()
        let ahead = (enqueuedEnd - now).seconds
        let videoAhead = (videoEnqueuedEnd - now).seconds
        // Decoded frames: while the clock is held the display layer takes only a few, so the video
        // side needs a frame at the target to start, and holds later only if frames fall behind the
        // clock (not the audio's 0.25 s, which a held layer never reaches: a deadlock on the iPhone).
        let videoCounts = videoTrack != nil && videoActive && !videoEnded
        let videoStarved = videoCounts && (videoFrames == 0 || videoAhead < 0)
        let starved = (!streamEnded && ahead < Self.holdBelow) || videoStarved
        if debounce.update(starved: starved && failure == nil && !ended, now: .now) {
            if !debounce.holding { holdReason = .underrun }
            log("local hold=\(debounce.holding) ahead=\(Self.format(ahead))")
            applyRate()
        }
        if streamEnded, !ended, now >= enqueuedEnd {
            ended = true
            log("local ended at=\(Self.format(now.seconds))")
            applyRate()
        }
        publish()
    }

    private func applyRate() {
        let target: Float = wantsToPlay && !debounce.holding && failure == nil && !ended && !closed ? speed : 0
        if synchronizer.rate != target { synchronizer.rate = target }
    }

    private func publish() {
        let snapshot = snapshot()
        // Positions move every tick: publish on any change but a position drift under 0.25 s.
        if let last = lastPublished, last.status == snapshot.status, last.wantsToPlay == snapshot.wantsToPlay,
           last.removeMusic == snapshot.removeMusic, last.speed == snapshot.speed, abs(last.position - snapshot.position) < 0.25 {
            return
        }
        lastPublished = snapshot
        onChange(snapshot)
    }

    private func fail(_ error: any Error) {
        guard failure == nil else { return }
        failure = "\(error)"
        log("local failed error=\(error)")
        applyRate()
        publish()
    }

    private func queued(_ lane: Lane) -> (any AVQueuedSampleBufferRendering)? {
        switch lane {
        case .audio: renderer
        case .video: videoRenderer
        }
    }

    private func wait(for lane: Lane) async {
        guard let target = queued(lane) else { return }
        await withCheckedContinuation { continuation in
            waiters.removeValue(forKey: lane)?.resume()
            waiters[lane] = continuation
            target.requestMediaDataWhenReady(on: queue) { [weak self] in
                Task { await self?.ready(lane) }
            }
        }
    }

    private func ready(_ lane: Lane) {
        queued(lane)?.stopRequestingMediaData()
        waiters.removeValue(forKey: lane)?.resume()
    }

    static func format(_ seconds: Double) -> String { String(format: "%.2f", seconds) }
}
