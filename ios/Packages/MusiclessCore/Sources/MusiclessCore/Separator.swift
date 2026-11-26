import AVFoundation
import Foundation
import os

/// Turns PCM into voices on Android's window grid (US-005; a port of `MusiclessAudioProcessor`,
/// which is the authority when the two disagree).
///
/// - After every start or flush, window sizes go 64, 128, 256, 512, 512, … frames. Each window's
///   input begins with the previous window's last 2048 input samples, and each window emits
///   `size * hop - 2048` samples, crossfading its first 2048 into the previous window's tail.
/// - At most 2 windows are outstanding (queued + running + finished but not yet taken); `enqueue`
///   suspends until one is taken, so the decoder can't race through the whole file.
/// - A flush bumps a generation counter; results of an older generation are dropped.
/// - `passThrough` (a file already saved without music) skips the models.
/// - A failure emits silence for every received frame, never the original audio, and reports it.
///
/// One producer calls `configure`, `enqueue` and `endOfStream`; one consumer takes chunks with
/// `nextChunk()` (or iterates `chunks`). Frames are counted at 44.1 kHz from the last flush.
public actor Separator {
    public struct Chunk: Sendable {
        public let generation: Int
        /// First frame of `voices`, at 44.1 kHz, counted from the last configure or flush.
        public let startFrame: Int64
        /// Interleaved stereo at 44.1 kHz. Empty on the end-of-stream marker.
        public let voices: [Float]
        /// The last chunk after `endOfStream()`; it carries no audio.
        public let isEndOfStream: Bool
        /// Silence written because separation failed.
        public let isSilence: Bool
        /// The window's stage times; nil for silence and the end marker.
        public let timings: WindowTimings?

        public var frameCount: Int { voices.count / 2 }
        var countsAsOutstanding: Bool { !isEndOfStream }
    }

    public static let maxOutstanding = 2
    private static let overlap = Dsp.overlap
    private static let fullWindow = Dsp.maxFrames * Dsp.hop
    private static let firstWindow = Dsp.rampFrames[0] * Dsp.hop
    private static let ids = OSAllocatedUnfairLock(initialState: 0)

    public nonisolated let id: Int
    private let backend: SeparationBackend
    private let log: @Sendable (String) -> Void

    private var converter: InputConverter?
    private var configured = false
    private var acquired = false
    private var closed = false

    // The window grid.
    private var input = [Float](repeating: 0, count: Separator.fullWindow * 2)
    private var filled = 0
    private var window = Separator.firstWindow
    private var receivedFrames: Int64 = 0
    private var submittedFrames: Int64 = 0
    private var takenFrames: Int64 = 0
    private var windowNumber = 0
    public private(set) var generation = 0
    public private(set) var passThrough = false

    // Work in flight.
    private struct Job: Sendable {
        let generation: Int
        let number: Int
        let block: [Float]
        let outputStart: Int64
        let outputFrames: Int
        let passThrough: Bool
        let submittedAt: ContinuousClock.Instant
    }
    private var outstanding = 0
    private var pending: [Job] = []
    private var running = false
    private var ready: [Chunk] = []
    private var tail: [Float]?
    private var tailGeneration = -1
    private var draining = false
    private var ended = false
    public private(set) var failureMessage: String?

    /// Android's hold fields (`MusiclessAudioProcessor.inputReadyNs`, `queueMs`, `waitModelMs`,
    /// `inferMs`): what the player's `hold reason=…` line reports.
    public struct HoldStats: Sendable, Equatable {
        /// When the first window after `beginHold()` was submitted; nil while input is still missing.
        public var inputReadyAt: ContinuousClock.Instant?
        public var queueMs = 0
        public var waitModelMs = 0
        public var inferMs = 0

        public init() {}
    }
    public private(set) var holdStats = HoldStats()

    private var capacityWaiters: [CheckedContinuation<Void, Never>] = []
    private var chunkWaiter: CheckedContinuation<Chunk?, Never>?

    public init(backend: SeparationBackend, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.backend = backend
        self.log = log
        id = Self.ids.withLock { value in
            value += 1
            return value
        }
    }

    // MARK: Producer

    /// Sets the input format (any rate, 1 or 2 channels, interleaved Float32) and flushes.
    public func configure(sampleRate: Double, channels: Int) async throws {
        guard sampleRate > 0, channels == 1 || channels == 2 else {
            throw SeparatorError("Unsupported input: \(sampleRate) Hz, \(channels) channels")
        }
        converter = sampleRate == Double(Dsp.sampleRate) && channels == 2
            ? nil : try InputConverter(sampleRate: sampleRate, channels: channels)
        configured = true
        if !acquired {
            acquired = true
            await backend.acquire()
        }
        flush()
        log("Processor acquire processor=\(id) rate=\(Int(sampleRate)) channels=\(channels)")
    }

    /// Adds interleaved samples in the configured format. Suspends while 2 windows are outstanding;
    /// returns early, dropping the rest, if a flush or close happens meanwhile (they belong to the
    /// old position). With `generation`, samples sent for an older generation are dropped: a player
    /// whose call races its own flush can't leak the old position into the new one.
    public func enqueue(_ samples: [Float], generation expected: Int? = nil) async {
        precondition(configured, "configure(sampleRate:channels:) first")
        if let expected, expected != generation { return }
        let stereo = converter.map { $0.convert(samples) } ?? samples
        await accept(stereo, generation: generation)
    }

    /// No more input until the next flush: the remaining samples go out as a short last window,
    /// then an end-of-stream chunk. Ignored when `generation` is given and is not the current one.
    public func endOfStream(generation expected: Int? = nil) async {
        if let expected, expected != generation { return }
        let token = generation
        if let tail = converter?.drain(), !tail.isEmpty { await accept(tail, generation: token) }
        guard token == generation, !closed else { return }
        draining = true
        submitDrainIfPossible()
        finishIfDrained()
    }

    /// Drops everything queued or finished and restarts the window ramp at frame 0. Optionally
    /// switches pass-through (FR-5: toggling Remove music flushes at the current position).
    /// Returns the new generation, which the chunks of the new position carry.
    @discardableResult
    public func flush(passThrough: Bool? = nil) -> Int {
        if let passThrough { self.passThrough = passThrough }
        generation += 1
        outstanding -= pending.count + ready.filter(\.countsAsOutstanding).count
        pending.removeAll()
        ready.removeAll()
        // A running job keeps its slot until it returns and sees the new generation.
        input = [Float](repeating: 0, count: Self.fullWindow * 2)
        filled = 0
        window = Self.firstWindow
        receivedFrames = 0
        submittedFrames = 0
        takenFrames = 0
        draining = false
        ended = false
        failureMessage = nil
        converter?.reset()
        resumeCapacityWaiters()
        return generation
    }

    /// Android's `beginHold`: the player started waiting for voices; restart the hold timings.
    public func beginHold() {
        holdStats = HoldStats()
    }

    /// Ends this separator: releases the backend and wakes any waiting caller.
    public func close() async {
        closed = true
        flush()
        chunkWaiter?.resume(returning: nil)
        chunkWaiter = nil
        if acquired {
            acquired = false
            await backend.release()
            log("Processor release processor=\(id)")
        }
    }

    // MARK: Consumer

    /// The next chunk in order, waiting for it if needed; nil once closed.
    public func nextChunk() async -> Chunk? {
        if let chunk = takeReady() { return chunk }
        if closed { return nil }
        precondition(chunkWaiter == nil, "Separator supports one consumer")
        return await withCheckedContinuation { chunkWaiter = $0 }
    }

    /// The chunks as an async sequence (one iterator at a time).
    public nonisolated var chunks: AsyncStream<Chunk> {
        AsyncStream { [self] in await self.nextChunk() }
    }

    /// Frames received but not yet taken by the consumer (Android's `hasPendingData`).
    public var hasPendingFrames: Bool { receivedFrames > takenFrames }
    public var outstandingWindows: Int { outstanding }

    // MARK: Grid

    private func accept(_ stereo: [Float], generation token: Int) async {
        let frames = stereo.count / 2
        var index = 0
        while index < frames {
            guard token == generation, !closed else { return }
            if outstanding >= Self.maxOutstanding {
                await withCheckedContinuation { capacityWaiters.append($0) }
                continue
            }
            if failureMessage != nil {
                // Failed: the rest is silence of the same length, still one chunk per slot.
                let count = frames - index
                receivedFrames += Int64(count)
                appendSilence(frames: count)
                return
            }
            let take = min(window - filled, frames - index)
            input.withUnsafeMutableBufferPointer { destination in
                stereo.withUnsafeBufferPointer { source in
                    (destination.baseAddress! + filled * 2)
                        .update(from: source.baseAddress! + index * 2, count: take * 2)
                }
            }
            filled += take
            index += take
            receivedFrames += Int64(take)
            if filled == window { submit(outputFrames: window - Self.overlap) }
        }
    }

    private func submit(outputFrames: Int) {
        if holdStats.inputReadyAt == nil { holdStats.inputReadyAt = .now }
        let block = window == Self.fullWindow ? input : Array(input[0..<(window * 2)])
        var next = [Float](repeating: 0, count: Self.fullWindow * 2)
        next[0..<(Self.overlap * 2)] = block[(block.count - Self.overlap * 2)...]
        input = next
        // Ramp 64 -> 128 -> 256 -> 512 frames so early windows finish before the queued audio runs out.
        window = min(window * 2, Self.fullWindow)
        filled = Self.overlap
        windowNumber += 1
        pending.append(Job(generation: generation, number: windowNumber, block: block,
                           outputStart: submittedFrames, outputFrames: outputFrames,
                           passThrough: passThrough, submittedAt: .now))
        submittedFrames += Int64(outputFrames)
        outstanding += 1
        startWorker()
    }

    private func submitDrainIfPossible() {
        guard draining, failureMessage == nil, receivedFrames > submittedFrames,
              outstanding < Self.maxOutstanding else { return }
        submit(outputFrames: Int(receivedFrames - submittedFrames))
    }

    private func startWorker() {
        guard !running, !pending.isEmpty else { return }
        running = true
        let job = pending.removeFirst()
        Task { await self.run(job) }
    }

    private func run(_ job: Job) async {
        defer {
            running = false
            startWorker()
            finishIfDrained()
        }
        guard job.generation == generation, failureMessage == nil else {
            releaseSlot()
            return
        }
        do {
            let result = try await backend.separate(job.block, passThrough: job.passThrough,
                                                    submittedAt: job.submittedAt)
            guard job.generation == generation, failureMessage == nil else {
                releaseSlot()
                return
            }
            let voices = crossfade(result.voices, outputFrames: job.outputFrames, generation: job.generation)
            let timings = result.timings
            holdStats.queueMs = timings.queueMs
            holdStats.waitModelMs = timings.waitModelMs
            holdStats.inferMs = timings.pipelineMs
            log("Window pipeline ms=\(timings.pipelineMs) processor=\(id) generation=\(job.generation) "
                + "window=\(job.number) frames=\(job.block.count / (2 * Dsp.hop)) outputStartFrame=\(job.outputStart) "
                + "outputFrames=\(job.outputFrames) \(timings.logFields) backend=\(timings.backend)")
            ready.append(Chunk(generation: job.generation, startFrame: job.outputStart, voices: voices,
                               isEndOfStream: false, isSilence: false, timings: timings))
            deliver()
        } catch {
            releaseSlot()
            if job.generation == generation { fail(error) }
        }
    }

    /// Android's `Worker.separate`: the first 2048 output samples rise into the previous window's
    /// falling tail; this window's last 2048 become the next tail.
    private func crossfade(_ output: [Float], outputFrames: Int, generation: Int) -> [Float] {
        var output = output
        if tailGeneration != generation {
            tail = nil
            tailGeneration = generation
        }
        let overlap = Self.overlap
        if let tail {
            for i in 0..<overlap {
                let rise = (Float(i) + 0.5) / Float(overlap)
                output[i * 2] = tail[i * 2] + output[i * 2] * rise
                output[i * 2 + 1] = tail[i * 2 + 1] + output[i * 2 + 1] * rise
            }
        }
        var next = Array(output[(output.count - overlap * 2)...])
        for i in 0..<overlap {
            let fall = 1 - (Float(i) + 0.5) / Float(overlap)
            next[i * 2] *= fall
            next[i * 2 + 1] *= fall
        }
        tail = next
        return Array(output[0..<(outputFrames * 2)])
    }

    private func fail(_ error: Error) {
        failureMessage = "\(error)"
        log("Separation failed; output remains silent processor=\(id) error=\(error)")
        outstanding -= pending.count + ready.filter(\.countsAsOutstanding).count
        pending.removeAll()
        ready.removeAll()
        // Everything received and not yet taken becomes silence, so the timeline stays whole.
        let missing = Int(receivedFrames - takenFrames)
        if missing > 0 { appendSilence(frames: missing, from: takenFrames) }
        resumeCapacityWaiters()
    }

    private func appendSilence(frames: Int, from start: Int64? = nil) {
        let startFrame = start ?? (receivedFrames - Int64(frames))
        ready.append(Chunk(generation: generation, startFrame: startFrame,
                           voices: [Float](repeating: 0, count: frames * 2),
                           isEndOfStream: false, isSilence: true, timings: nil))
        outstanding += 1
        deliver()
    }

    private func finishIfDrained() {
        guard draining, !ended, pending.isEmpty, !running,
              failureMessage != nil || receivedFrames == submittedFrames else { return }
        ended = true
        ready.append(Chunk(generation: generation, startFrame: receivedFrames, voices: [],
                           isEndOfStream: true, isSilence: false, timings: nil))
        deliver()
    }

    private func takeReady() -> Chunk? {
        guard !ready.isEmpty else { return nil }
        let chunk = ready.removeFirst()
        takenFrames = chunk.startFrame + Int64(chunk.frameCount)
        if chunk.countsAsOutstanding { releaseSlot() }
        return chunk
    }

    private func deliver() {
        guard let waiter = chunkWaiter, let chunk = takeReady() else { return }
        chunkWaiter = nil
        waiter.resume(returning: chunk)
    }

    private func releaseSlot() {
        outstanding -= 1
        resumeCapacityWaiters()
        submitDrainIfPossible()
    }

    private func resumeCapacityWaiters() {
        let waiters = capacityWaiters
        capacityWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

public struct SeparatorError: Error, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Converts interleaved Float32 at any rate, mono or stereo, to 44.1 kHz stereo (PRD §4.3: Android
/// interpolates linearly; iOS uses AVAudioConverter). Mono at 44.1 kHz is just duplicated.
final class InputConverter {
    private let channels: Int
    private let inputFormat: AVAudioFormat
    private let converter: AVAudioConverter?
    private let ratio: Double

    init(sampleRate: Double, channels: Int) throws {
        self.channels = channels
        ratio = Double(Dsp.sampleRate) / sampleRate
        guard let input = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                        channels: AVAudioChannelCount(channels), interleaved: true),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Dsp.sampleRate),
                                         channels: 2, interleaved: true) else {
            throw SeparatorError("Cannot describe \(sampleRate) Hz, \(channels) channels")
        }
        inputFormat = input
        if sampleRate == Double(Dsp.sampleRate) {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: input, to: output) else {
                throw SeparatorError("No converter from \(sampleRate) Hz, \(channels) channels")
            }
            // Mono to stereo copies the channel instead of mixing it down 3 dB.
            if channels == 1 { converter.channelMap = [0, 0] }
            self.converter = converter
        }
    }

    func convert(_ samples: [Float]) -> [Float] {
        guard let converter else { return duplicate(samples) }
        return run(converter, samples: samples, endOfStream: false)
    }

    /// What the resampler still holds at the end of the stream.
    func drain() -> [Float] {
        guard let converter else { return [] }
        defer { converter.reset() }
        return run(converter, samples: [], endOfStream: true)
    }

    func reset() { converter?.reset() }

    private func duplicate(_ samples: [Float]) -> [Float] {
        guard channels == 1 else { return samples }
        var stereo = [Float](repeating: 0, count: samples.count * 2)
        for (i, sample) in samples.enumerated() {
            stereo[i * 2] = sample
            stereo[i * 2 + 1] = sample
        }
        return stereo
    }

    private func run(_ converter: AVAudioConverter, samples: [Float], endOfStream: Bool) -> [Float] {
        let frames = samples.count / channels
        let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        source.frameLength = AVAudioFrameCount(frames)
        if frames > 0 {
            samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        }
        let capacity = AVAudioFrameCount(Double(frames) * ratio) + 4096
        let feed = Feed(buffer: source, endOfStream: endOfStream)
        var result: [Float] = []
        while true {
            let target = AVAudioPCMBuffer(pcmFormat: converter.outputFormat, frameCapacity: capacity)!
            var error: NSError?
            let status = converter.convert(to: target, error: &error) { _, inputStatus in feed.next(inputStatus) }
            let produced = Int(target.frameLength) * 2
            if produced > 0 {
                result += UnsafeBufferPointer(start: target.floatChannelData![0], count: produced)
            }
            if status != .haveData || target.frameLength < capacity { break }
        }
        return result
    }

    /// Hands the converter one buffer, then "no data now" (or end of stream).
    private final class Feed: @unchecked Sendable {  // used synchronously inside convert(to:)
        private let buffer: AVAudioPCMBuffer
        private let endOfStream: Bool
        private var given = false

        init(buffer: AVAudioPCMBuffer, endOfStream: Bool) {
            self.buffer = buffer
            self.endOfStream = endOfStream
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if !given && buffer.frameLength > 0 {
                given = true
                status.pointee = .haveData
                return buffer
            }
            status.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
    }
}
