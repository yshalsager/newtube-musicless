import Foundation
import MusiclessCore
import Testing

/// US-005: the Separator's grid, mirroring Android's MusiclessAudioProcessorTest where it applies.
@Suite struct SeparatorTests {
    @Test func identityOutputHasExactlyOneFramePerInputWithoutShiftOrDuplicateOverlap() async throws {
        let backend = RecordingBackend()
        let separator = Separator(backend: backend)
        try await separator.configure(sampleRate: 44_100, channels: 2)
        let input = Self.ramp(frames: 700_000)
        let collector = Task { await Self.collect(separator) }
        for start in stride(from: 0, to: input.count, by: 8_192) {
            await separator.enqueue(Array(input[start..<min(start + 8_192, input.count)]))
        }
        await separator.endOfStream()
        let chunks = await collector.value

        let output = chunks.flatMap(\.voices)
        #expect(output.count == input.count)
        var maxError: Float = 0
        for (a, b) in zip(output, input) { maxError = max(maxError, abs(a - b)) }
        #expect(maxError < 1e-5, "identity windows crossfade back to the input (max error \(maxError))")
        var expected: Int64 = 0
        for chunk in chunks {
            #expect(chunk.startFrame == expected)
            expected += Int64(chunk.frameCount)
        }
        #expect(chunks.last?.isEndOfStream == true)
    }

    @Test func windowsRampFrom64To512AndRepeat() async throws {
        let backend = RecordingBackend()
        let separator = Separator(backend: backend)
        try await separator.configure(sampleRate: 44_100, channels: 2)
        let collector = Task { await Self.collect(separator) }
        await separator.enqueue(Self.ramp(frames: 1_600_000))
        await separator.endOfStream()
        let chunks = await collector.value
        let frames = await backend.frames
        #expect(Array(frames.prefix(5)) == [64, 128, 256, 512, 512])
        // Each full window emits size * hop - overlap frames.
        #expect(Array(chunks.prefix(4).map(\.frameCount)) == [64, 128, 256, 512].map { $0 * Dsp.hop - Dsp.overlap })
    }

    @Test func atMostTwoWindowsOutstandingAndEnqueueWaits() async throws {
        let backend = GatedBackend()
        let separator = Separator(backend: backend)
        try await separator.configure(sampleRate: 44_100, channels: 2)
        let producer = Task { await separator.enqueue(Self.ramp(frames: 1_000_000)) }
        try await Self.eventually { await separator.outstandingWindows == 2 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await separator.outstandingWindows == 2)
        #expect(await backend.started == 1, "one window runs, the next waits behind it")

        await backend.open(count: 2)
        // Finished windows still count until the consumer takes them.
        try await Self.eventually { await backend.finished == 2 }
        #expect(await separator.outstandingWindows == 2)
        _ = await separator.nextChunk()
        try await Self.eventually { await backend.started == 3 }
        #expect(await separator.outstandingWindows <= 2)
        await separator.close()
        await backend.open(count: 100)
        await producer.value
    }

    @Test func flushDiscardsInFlightWorkAndRestartsAtFrameZero() async throws {
        let backend = GatedBackend()
        let separator = Separator(backend: backend)
        try await separator.configure(sampleRate: 44_100, channels: 2)
        let old = Task { await separator.enqueue(Self.ramp(frames: 400_000)) }
        try await Self.eventually { await backend.started == 1 }

        await separator.flush()
        await old.value  // the suspended producer returns: its samples belong to the old position
        await backend.open(count: 100)
        let fresh = Self.ramp(frames: 70_000, offset: 0.5)
        await separator.enqueue(fresh)
        await separator.endOfStream()

        var chunks: [Separator.Chunk] = []
        while let chunk = await separator.nextChunk() {
            chunks.append(chunk)
            if chunk.isEndOfStream { break }
        }
        let generation = await separator.generation
        #expect(chunks.allSatisfy { $0.generation == generation })
        #expect(chunks.first?.startFrame == 0)
        #expect(chunks.flatMap(\.voices).count == fresh.count)
        await separator.close()
    }

    @Test func repeatedFlushCannotAccumulateStaleJobs() async throws {
        let backend = GatedBackend()
        let separator = Separator(backend: backend)
        try await separator.configure(sampleRate: 44_100, channels: 2)
        for _ in 0..<10 {
            let producer = Task { await separator.enqueue(Self.ramp(frames: 200_000)) }
            // Wait until the producer is really blocked (a sleep raced under parallel tests: a flush
            // before the producer started left it waiting forever behind the closed gate).
            try await Self.eventually { await separator.outstandingWindows == 2 }
            await separator.flush()
            await producer.value
            #expect(await separator.outstandingWindows <= 1, "only the running job may keep its slot")
        }
        await backend.open(count: 100)
        try await Self.eventually { await separator.outstandingWindows == 0 }
        await separator.close()
    }

    @Test func failureEmitsSilenceOfTheSameLengthAndNeverTheInput() async throws {
        let backend = RecordingBackend(failOnWindow: 2)
        let separator = Separator(backend: backend)
        try await separator.configure(sampleRate: 44_100, channels: 2)
        let collector = Task { await Self.collect(separator) }
        let input = Self.ramp(frames: 500_000, offset: 0.25)
        await separator.enqueue(input)
        await separator.endOfStream()
        let chunks = await collector.value

        let output = chunks.flatMap(\.voices)
        #expect(output.count == input.count)
        let firstWindow = 64 * Dsp.hop - Dsp.overlap
        #expect(chunks.first?.isSilence == false)
        #expect(output[(firstWindow * 2)...].allSatisfy { $0 == 0 }, "after the failure only silence")
        #expect(await separator.failureMessage != nil)
    }

    @Test func passThroughIsHandedToTheBackendAfterAFlush() async throws {
        let backend = RecordingBackend()
        let separator = Separator(backend: backend)
        try await separator.configure(sampleRate: 44_100, channels: 2)
        await separator.flush(passThrough: true)
        let collector = Task { await Self.collect(separator) }
        await separator.enqueue(Self.ramp(frames: 70_000))
        await separator.endOfStream()
        _ = await collector.value
        #expect(await backend.passThroughFlags.allSatisfy { $0 })
        #expect(await separator.passThrough)
    }

    @Test func otherRatesAndMonoAreConvertedTo44100Stereo() async throws {
        let backend = RecordingBackend()
        let separator = Separator(backend: backend)
        try await separator.configure(sampleRate: 48_000, channels: 1)
        let collector = Task { await Self.collect(separator) }
        let second = (0..<48_000).map { Float(sin(2 * Double.pi * 440 * Double($0) / 48_000)) * 0.5 }
        for start in stride(from: 0, to: second.count, by: 4_800) {
            await separator.enqueue(Array(second[start..<(start + 4_800)]))
        }
        await separator.endOfStream()
        let chunks = await collector.value
        let frames = chunks.reduce(0) { $0 + $1.frameCount }
        #expect(abs(frames - 44_100) <= 64, "1 s at 48 kHz becomes ~44,100 frames, got \(frames)")
        let voices = chunks.flatMap(\.voices)
        let middle = voices.count / 2 & ~1
        #expect(voices[middle] == voices[middle + 1], "mono is copied to both channels")
    }

    @Test func inputForAnOlderGenerationIsDropped() async throws {
        let backend = RecordingBackend()
        let separator = Separator(backend: backend)
        try await separator.configure(sampleRate: 44_100, channels: 2)
        let old = await separator.generation
        let fresh = await separator.flush()
        #expect(fresh == old + 1)
        let collector = Task { await Self.collect(separator) }
        await separator.enqueue(Self.ramp(frames: 100_000, offset: 9), generation: old)  // a late call from the old position
        await separator.endOfStream(generation: old)
        let input = Self.ramp(frames: 70_000)
        await separator.enqueue(input, generation: fresh)
        await separator.endOfStream(generation: fresh)
        let chunks = await collector.value
        #expect(chunks.allSatisfy { $0.generation == fresh })
        #expect(chunks.flatMap(\.voices).count == input.count, "only the current generation's samples come out")
    }

    @Test func holdStatsFollowAndroidsFields() async throws {
        let backend = GatedBackend()
        let separator = Separator(backend: backend)
        try await separator.configure(sampleRate: 44_100, channels: 2)
        await separator.beginHold()
        #expect(await separator.holdStats.inputReadyAt == nil)
        let before = ContinuousClock.now
        let producer = Task { await separator.enqueue(Self.ramp(frames: 30_000)) }
        await producer.value
        #expect(await separator.holdStats.inputReadyAt == nil, "half a first window is not input ready")
        await separator.enqueue(Self.ramp(frames: 40_000))
        let ready = try #require(await separator.holdStats.inputReadyAt)
        #expect(ready >= before)
        await backend.open(count: 1)
        _ = await separator.nextChunk()
        await separator.beginHold()
        #expect(await separator.holdStats == Separator.HoldStats())
        await separator.close()
        await backend.open(count: 100)
    }

    // MARK: Helpers

    /// Interleaved stereo with distinct, smoothly varying channels.
    static func ramp(frames: Int, offset: Float = 0) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * 2)
        for i in 0..<frames {
            samples[i * 2] = sinf(Float(i) * 0.001 + offset) * 0.5
            samples[i * 2 + 1] = cosf(Float(i) * 0.0007 + offset) * 0.25
        }
        return samples
    }

    static func collect(_ separator: Separator) async -> [Separator.Chunk] {
        var chunks: [Separator.Chunk] = []
        while let chunk = await separator.nextChunk() {
            chunks.append(chunk)
            if chunk.isEndOfStream { break }
        }
        return chunks
    }

    static func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Fake backends

/// Returns the input (Android's identity worker), recording window sizes; can fail one window.
actor RecordingBackend: SeparationBackend {
    private(set) var frames: [Int] = []
    private(set) var passThroughFlags: [Bool] = []
    private let failOnWindow: Int?

    init(failOnWindow: Int? = nil) { self.failOnWindow = failOnWindow }

    func separate(_ block: [Float], passThrough: Bool, submittedAt: ContinuousClock.Instant) async throws -> SeparatedWindow {
        frames.append(block.count / (2 * Dsp.hop))
        passThroughFlags.append(passThrough)
        if frames.count == failOnWindow { throw SeparatorTestError.injected }
        return SeparatedWindow(voices: block, timings: WindowTimings(backend: "identity"))
    }

    func acquire() {}
    func release() {}
}

/// Identity, but each window waits until the test opens the gate for it.
actor GatedBackend: SeparationBackend {
    private(set) var started = 0
    private(set) var finished = 0
    private var permits = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open(count: Int) {
        permits += count
        while permits > 0, !waiters.isEmpty {
            permits -= 1
            waiters.removeFirst().resume()
        }
    }

    func separate(_ block: [Float], passThrough: Bool, submittedAt: ContinuousClock.Instant) async throws -> SeparatedWindow {
        started += 1
        if permits > 0 {
            permits -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
        finished += 1
        return SeparatedWindow(voices: block, timings: WindowTimings(backend: "gated"))
    }

    func acquire() {}
    func release() {}
}

enum SeparatorTestError: Error { case injected }
