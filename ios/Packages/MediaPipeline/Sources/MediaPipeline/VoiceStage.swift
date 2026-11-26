import Foundation

/// What the player runs decoded audio through: MusiclessCore's `Separator` in the app (through a
/// small adapter, so this package needs no ONNX Runtime), fakes in tests. The shape is the
/// Separator's: interleaved Float32 in at any rate, voices out at 44.1 kHz stereo, at most a couple
/// of windows ahead, with generations so a flush can't leak the old position into the new one.
public protocol VoiceStage: Sendable {
    /// The input format (any rate, 1 or 2 channels, interleaved Float32); flushes.
    func configure(sampleRate: Double, channels: Int) async throws
    /// Drops everything and restarts at frame 0, optionally switching pass-through (Remove music
    /// off). Returns the new generation.
    func flush(passThrough: Bool?) async -> Int
    /// Suspends while the stage is full; drops samples sent for another generation.
    func enqueue(_ samples: [Float], generation: Int) async
    /// The remaining input goes out, then an end-of-stream chunk.
    func endOfStream(generation: Int) async
    /// The next chunk in order (one consumer); nil once closed.
    func nextChunk() async -> VoiceChunk?
    /// Android's `beginHold`: restarts the timings the next `hold` line reports.
    func beginHold() async
    func holdStats() async -> VoiceHoldStats
    func close() async
}

public struct VoiceChunk: Sendable {
    public var generation: Int
    /// First frame, at 44.1 kHz, counted from the last flush.
    public var startFrame: Int64
    /// Interleaved stereo at 44.1 kHz; empty on the end-of-stream marker.
    public var samples: [Float]
    public var isEndOfStream: Bool
    /// Silence written because separation failed.
    public var isSilence: Bool

    public init(generation: Int, startFrame: Int64, samples: [Float], isEndOfStream: Bool, isSilence: Bool = false) {
        self.generation = generation
        self.startFrame = startFrame
        self.samples = samples
        self.isEndOfStream = isEndOfStream
        self.isSilence = isSilence
    }

    public var frameCount: Int { samples.count / 2 }
}

/// The fields of Android's `hold reason=…` line that come from the separation stage.
public struct VoiceHoldStats: Sendable, Equatable {
    /// When the first window after `beginHold()` had all its input; nil while input is missing.
    public var inputReadyAt: ContinuousClock.Instant?
    public var queueMs: Int
    public var waitModelMs: Int
    public var inferMs: Int

    public init(inputReadyAt: ContinuousClock.Instant? = nil, queueMs: Int = 0, waitModelMs: Int = 0, inferMs: Int = 0) {
        self.inputReadyAt = inputReadyAt
        self.queueMs = queueMs
        self.waitModelMs = waitModelMs
        self.inferMs = inferMs
    }
}

/// Android's `MusiclessAudioSink.HoldDebounce`: starvation must last 100 ms before it holds the
/// clock (short gaps while chunks are written aren't holds); leaving a hold is immediate.
public struct HoldDebounce: Sendable, Equatable {
    public static let delay: Duration = .milliseconds(100)

    /// When the current starvation began; nil when not starved.
    public private(set) var since: ContinuousClock.Instant?
    public private(set) var holding = false

    public init() {}

    /// Returns true when the debounced hold state changed.
    public mutating func update(starved: Bool, now: ContinuousClock.Instant) -> Bool {
        if !starved {
            since = nil
        } else if since == nil {
            since = now
        }
        let next = starved && (holding || since.map { now - $0 >= Self.delay } ?? false)
        if next == holding { return false }
        holding = next
        return true
    }

    /// Forces the state (a start or seek holds at once).
    public mutating func set(_ value: Bool, now: ContinuousClock.Instant) {
        holding = value
        since = value ? now : nil
    }
}
