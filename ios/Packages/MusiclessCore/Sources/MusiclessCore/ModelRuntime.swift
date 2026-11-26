import Accelerate
import Dispatch
import Foundation

/// Per-window stage times, the fields of Android's `Window pipeline` log line.
public struct WindowTimings: Sendable, Equatable {
    public var backend: String
    public var queueMs = 0
    public var waitModelMs = 0
    public var analyzeMs = 0
    public var vocalsMs = 0
    public var accompanimentMs = 0
    public var maskMs = 0
    public var synthesizeMs = 0
    public var otherMs = 0
    public var cpuMs = 0
    /// analyze + both models + mask + synthesize (Android's `pipelineMs` / `inferMs`).
    public var pipelineMs = 0

    public init(backend: String) { self.backend = backend }

    /// `queueMs=… waitModelMs=… analyzeMs=… … cpuMs=…`, in Android's order.
    public var logFields: String {
        "queueMs=\(queueMs) waitModelMs=\(waitModelMs) analyzeMs=\(analyzeMs) vocalsMs=\(vocalsMs) "
            + "accompanimentMs=\(accompanimentMs) maskMs=\(maskMs) synthesizeMs=\(synthesizeMs) otherMs=\(otherMs) cpuMs=\(cpuMs)"
    }
}

public struct SeparatedWindow: Sendable {
    /// Interleaved stereo voices, as many samples as the input block.
    public let voices: [Float]
    public let timings: WindowTimings

    public init(voices: [Float], timings: WindowTimings) {
        self.voices = voices
        self.timings = timings
    }
}

/// What the `Separator` runs each window through: `ModelRuntime` in the app, fakes in tests.
public protocol SeparationBackend: Sendable {
    /// `block`: interleaved stereo at 44.1 kHz, `frames * hop` frames, frames in 1...512.
    func separate(_ block: [Float], passThrough: Bool, submittedAt: ContinuousClock.Instant) async throws -> SeparatedWindow
    func acquire() async
    func release() async
}

/// Loads the two Spleeter sessions once and runs every window on one serial executor, as Android's
/// `MusiclessModelHolder` does with its single thread: loading, inference and disposal all happen
/// there (PRD §4.2, §4.3). Sessions are released 120 s after the last user leaves, and on a memory
/// warning when nobody uses them.
public actor ModelRuntime: SeparationBackend {
    public static let defaultIdleRelease: Duration = .seconds(120)

    public nonisolated let backend: InferenceBackend
    private let queue = DispatchSerialQueue(label: "Musicless-ORT", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let models: [URL]
    private let coreMLCache: URL?
    private let idleRelease: Duration
    private let awaitModels: @Sendable () async throws -> Void
    private let log: @Sendable (String) -> Void
    private var vocals: OnnxSession?
    private var accompaniment: OnnxSession?
    /// Only the full size is kept: ramp windows run a few times per seek and would pin ~22 MB (Android).
    private var full: Dsp?
    private var users = 0
    private var epoch = 0
    public private(set) var lastLoadMilliseconds: Int?

    /// - Parameters:
    ///   - models: the vocals and accompaniment model files (`ModelStore.modelURLs`).
    ///   - awaitModels: waits until those files exist (`ModelStore.awaitReady`), like Android's
    ///     `models.awaitReady()` inside `load`.
    public init(models: [URL], backend: InferenceBackend = .ortCPU, coreMLCache: URL? = nil,
                idleRelease: Duration = ModelRuntime.defaultIdleRelease,
                awaitModels: @escaping @Sendable () async throws -> Void = {},
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        precondition(models.count == 2, "expected the vocals and accompaniment models")
        self.models = models
        self.backend = backend
        self.coreMLCache = coreMLCache
        self.idleRelease = idleRelease
        self.awaitModels = awaitModels
        self.log = log
    }

    public var isLoaded: Bool { vocals != nil && accompaniment != nil }
    public var userCount: Int { users }

    public func acquire() {
        users += 1
        epoch += 1
    }

    public func release() {
        if users > 0 { users -= 1 }
        scheduleRelease()
    }

    /// Android's `trimMemory`: drop the sessions only when no player is using them.
    public func didReceiveMemoryWarning() {
        if users == 0 { close() }
    }

    public func close() {
        vocals = nil
        accompaniment = nil
        full = nil
    }

    /// Returns the load time in ms, or 0 when the sessions were already loaded.
    @discardableResult
    public func load() async throws -> Int {
        if isLoaded { return 0 }
        try await awaitModels()
        if isLoaded { return 0 }  // another caller loaded them while this one waited
        let start = ContinuousClock.now
        do {
            vocals = try OnnxSession(model: models[0], backend: backend, coreMLCache: coreMLCache)
            accompaniment = try OnnxSession(model: models[1], backend: backend, coreMLCache: coreMLCache)
        } catch {
            close()
            throw error
        }
        let milliseconds = Self.milliseconds(since: start)
        lastLoadMilliseconds = milliseconds
        log("Model loaded ms=\(milliseconds) backend=\(backend.rawValue)")
        return milliseconds
    }

    public func separate(_ block: [Float], passThrough: Bool,
                         submittedAt: ContinuousClock.Instant) async throws -> SeparatedWindow {
        var timings = WindowTimings(backend: backend.rawValue)
        timings.queueMs = Self.milliseconds(since: submittedAt)
        if passThrough { return SeparatedWindow(voices: block, timings: timings) }

        let waitStart = ContinuousClock.now
        try await load()
        timings.waitModelMs = Self.milliseconds(since: waitStart)
        guard let vocals, let accompaniment else { throw OnnxError(message: "the models are not loaded") }

        // From here on everything is synchronous, so it stays on one thread and its CPU time is ours.
        let start = ContinuousClock.now
        let cpuStart = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        let frames = block.count / (2 * Dsp.hop)
        let dsp: Dsp
        if frames == Dsp.maxFrames {
            dsp = full ?? Dsp(frames: frames)
            full = dsp
        } else {
            dsp = Dsp(frames: frames)
        }

        var stage = ContinuousClock.now
        let analysis = dsp.analyze(block)
        timings.analyzeMs = Self.lap(&stage)

        var magnitude = analysis.magnitude
        let shape: [Int64] = [2, 1, Int64(frames), Int64(Dsp.bins)]
        var mask = [Float](repeating: 0, count: magnitude.count)
        try vocals.run(&magnitude, shape: shape) { voices in
            _ = mask.withUnsafeMutableBufferPointer { $0.update(fromContentsOf: voices) }
        }
        timings.vocalsMs = Self.lap(&stage)

        var maskNs: Duration = .zero
        try accompaniment.run(&magnitude, shape: shape) { music in
            let maskStart = ContinuousClock.now
            Self.voiceMask(&mask, music: music)
            maskNs = ContinuousClock.now - maskStart
        }
        let accompanimentAndMask = Self.lap(&stage)
        timings.maskMs = Int(maskNs / .milliseconds(1))
        timings.accompanimentMs = accompanimentAndMask - timings.maskMs

        let voices = dsp.synthesize(spectrum: analysis.spectrum, mask: mask)
        timings.synthesizeMs = Self.lap(&stage)

        timings.pipelineMs = Self.milliseconds(since: start)
        timings.otherMs = max(0, timings.pipelineMs - timings.analyzeMs - timings.vocalsMs
                                 - timings.accompanimentMs - timings.maskMs - timings.synthesizeMs)
        timings.cpuMs = Int((clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - cpuStart) / 1_000_000)
        return SeparatedWindow(voices: voices, timings: timings)
    }

    /// `mask = (v + 5e-11) / (v + 2a + 1e-10)`, element-wise in Float, in Java's operation order.
    static func voiceMask(_ voices: inout [Float], music: UnsafeBufferPointer<Float>) {
        let count = vDSP_Length(voices.count)
        var denominator = [Float](repeating: 0, count: voices.count)
        var two: Float = 2, small: Float = 1e-10, tiny: Float = 5e-11
        voices.withUnsafeMutableBufferPointer { v in
            denominator.withUnsafeMutableBufferPointer { d in
                vDSP_vsma(music.baseAddress!, 1, &two, v.baseAddress!, 1, d.baseAddress!, 1, count)  // 2a + v
                vDSP_vsadd(d.baseAddress!, 1, &small, d.baseAddress!, 1, count)
                vDSP_vsadd(v.baseAddress!, 1, &tiny, v.baseAddress!, 1, count)
                vDSP_vdiv(d.baseAddress!, 1, v.baseAddress!, 1, v.baseAddress!, 1, count)       // v / d
            }
        }
    }

    private func scheduleRelease() {
        guard users == 0 else { return }
        epoch += 1
        let token = epoch, delay = idleRelease
        Task {  // inherits this actor's isolation
            try? await Task.sleep(for: delay)
            releaseIfIdle(token)
        }
    }

    private func releaseIfIdle(_ token: Int) {
        if users == 0 && epoch == token { close() }
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }

    private static func lap(_ stage: inout ContinuousClock.Instant) -> Int {
        let now = ContinuousClock.now
        defer { stage = now }
        return Int((now - stage) / .milliseconds(1))
    }
}
