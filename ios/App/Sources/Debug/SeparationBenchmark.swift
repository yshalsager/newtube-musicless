import AVFoundation
import MusiclessCore
import Observation
import UIKit

/// US-006: separation speed on this phone, per backend, in the foreground and with the screen
/// locked. Writes one CSV row per window to Documents (visible in Files) and logs a summary.
///
/// The input is a deterministic synthetic signal rather than a bundled clip: the models do the same
/// arithmetic whatever the audio, and nothing has to be licensed or shipped (DECISIONS D33).
@MainActor @Observable
final class SeparationBenchmark {
    enum Phase: Equatable {
        case idle
        case waitingForLock
        case running(String)
        case done(String)
        case failed(String)
    }

    static let windowsPerSize = 10
    static let sizes = [64, 512]

    private(set) var phase: Phase = .idle
    private(set) var summary: [String] = []
    @ObservationIgnored private let models: ModelStore
    @ObservationIgnored private let silence = SilentAudio()

    init(models: ModelStore) { self.models = models }

    var isBusy: Bool {
        switch phase {
        case .waitingForLock, .running: true
        default: false
        }
    }

    /// `locked`: play silence (so iOS keeps the app running), wait until the screen locks (Auto-Lock
    /// or the side button), then run every backend in the background.
    func run(locked: Bool) async {
        guard !isBusy else { return }
        summary = []
        do {
            phase = .running("Waiting for the voice models")
            try await models.awaitReady()
            if locked {
                try silence.start()
                phase = .waitingForLock
                AppLog.benchmark.info("Benchmark waiting for the screen to lock")
                while UIApplication.shared.applicationState != .background {
                    try await Task.sleep(for: .milliseconds(250))
                }
                try await Task.sleep(for: .seconds(2))  // let the lock settle
            }
            let csv = try BenchmarkCSV(locked: locked)
            for backend in InferenceBackend.allCases {
                try await run(backend, csv: csv)
            }
            silence.stop()
            phase = .done("CSV in Files › On My iPhone › NewTube Musicless › \(csv.url.lastPathComponent)")
            AppLog.benchmark.info("Benchmark done csv=\(csv.url.lastPathComponent)")
        } catch {
            silence.stop()
            phase = .failed("\(error)")
            AppLog.benchmark.info("Benchmark failed error=\(error)")
        }
    }

    private func run(_ backend: InferenceBackend, csv: BenchmarkCSV) async throws {
        phase = .running("\(backend.rawValue): compiling")
        let cache = URL.cachesDirectory.appending(path: "coreml/\(backend.rawValue)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: cache)  // the first load compiles from scratch
        let runtime = ModelRuntime(models: models.modelURLs, backend: backend, coreMLCache: cache,
                                   log: { AppLog.musicless.info($0) })
        let loadFirst: Int, loadCached: Int
        do {
            loadFirst = try await runtime.load()
            await runtime.close()
            loadCached = try await runtime.load()
        } catch {
            summary.append("\(backend.rawValue): load failed: \(error)")
            csv.append(BenchmarkRow.failure(backend: backend, appState: Self.appState, error: "\(error)"))
            return
        }
        summary.append("\(backend.rawValue): load \(loadFirst) ms first, \(loadCached) ms cached")
        AppLog.benchmark.info("Benchmark load backend=\(backend.rawValue) firstMs=\(loadFirst) cachedMs=\(loadCached)")

        for frames in Self.sizes {
            let block = BenchmarkSignal.make(frames: frames)
            var pipeline: [Int] = []
            for run in 1...Self.windowsPerSize {
                phase = .running("\(backend.rawValue): F=\(frames) window \(run)/\(Self.windowsPerSize)")
                do {
                    let result = try await runtime.separate(block, passThrough: false, submittedAt: .now)
                    let row = BenchmarkRow(backend: backend, appState: Self.appState, frames: frames, run: run,
                                           timings: result.timings, footprintMB: ProcessMetrics.footprintMB,
                                           thermal: ProcessMetrics.thermalState,
                                           loadFirstMs: loadFirst, loadCachedMs: loadCached, error: "")
                    csv.append(row)
                    pipeline.append(result.timings.pipelineMs)
                    AppLog.benchmark.info("Benchmark " + row.logLine)
                } catch {
                    csv.append(BenchmarkRow.failure(backend: backend, appState: Self.appState, error: "\(error)"))
                    summary.append("\(backend.rawValue) F=\(frames): failed: \(error)")
                    break
                }
            }
            if !pipeline.isEmpty {
                let sorted = pipeline.dropFirst().sorted()
                let median = sorted.isEmpty ? pipeline[0] : sorted[sorted.count / 2]
                let line = "\(backend.rawValue) F=\(frames): first \(pipeline[0]) ms, median \(median) ms "
                    + "(\(Self.appState), \(ProcessMetrics.thermalState), \(ProcessMetrics.footprintMB) MB)"
                summary.append(line)
                AppLog.benchmark.info("Benchmark summary " + line)
            }
        }
        await runtime.close()
    }

    private static var appState: String {
        UIApplication.shared.applicationState == .background ? "bg" : "fg"
    }
}

/// One window's figures; the CSV's columns.
struct BenchmarkRow {
    static let header = "time,appState,backend,frames,run,pipelineMs,queueMs,waitModelMs,analyzeMs,vocalsMs,"
        + "accompanimentMs,maskMs,synthesizeMs,otherMs,cpuMs,footprintMB,thermal,loadFirstMs,loadCachedMs,error"

    let backend: InferenceBackend
    let appState: String
    let frames: Int
    let run: Int
    let timings: WindowTimings
    let footprintMB: Int
    let thermal: String
    let loadFirstMs: Int
    let loadCachedMs: Int
    let error: String

    static func failure(backend: InferenceBackend, appState: String, error: String) -> BenchmarkRow {
        BenchmarkRow(backend: backend, appState: appState, frames: 0, run: 0,
                     timings: WindowTimings(backend: backend.rawValue), footprintMB: ProcessMetrics.footprintMB,
                     thermal: ProcessMetrics.thermalState, loadFirstMs: -1, loadCachedMs: -1, error: error)
    }

    var csv: String {
        let t = timings
        let fields: [String] = [
            Date().ISO8601Format(), appState, backend.rawValue, "\(frames)", "\(run)", "\(t.pipelineMs)",
            "\(t.queueMs)", "\(t.waitModelMs)", "\(t.analyzeMs)", "\(t.vocalsMs)", "\(t.accompanimentMs)",
            "\(t.maskMs)", "\(t.synthesizeMs)", "\(t.otherMs)", "\(t.cpuMs)", "\(footprintMB)", thermal,
            "\(loadFirstMs)", "\(loadCachedMs)", "\"\(error.replacingOccurrences(of: "\"", with: "'"))\"",
        ]
        return fields.joined(separator: ",")
    }

    var logLine: String {
        "window backend=\(backend.rawValue) appState=\(appState) frames=\(frames) run=\(run) "
            + "ms=\(timings.pipelineMs) \(timings.logFields) footprintMB=\(footprintMB) thermal=\(thermal)"
    }
}

/// Documents/benchmark-<time>-<fg|locked>.csv.
final class BenchmarkCSV {
    let url: URL
    private let handle: FileHandle

    init(locked: Bool) throws {
        let stamp = Date().ISO8601Format(.iso8601.year().month().day().time(includingFractionalSeconds: false)
            .dateSeparator(.dash).timeSeparator(.omitted))
        url = URL.documentsDirectory.appending(path: "benchmark-\(stamp)-\(locked ? "locked" : "fg").csv")
        FileManager.default.createFile(atPath: url.path, contents: Data((BenchmarkRow.header + "\n").utf8))
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    func append(_ row: BenchmarkRow) {
        handle.write(Data((row.csv + "\n").utf8))
        try? handle.synchronize()
    }

    deinit { try? handle.close() }
}

/// A deterministic stereo mix of tones and noise at about -15 dBFS.
enum BenchmarkSignal {
    static func make(frames: Int) -> [Float] {
        let count = frames * Dsp.hop
        var samples = [Float](repeating: 0, count: count * 2)
        var noise: UInt32 = 0x1234_5678
        for i in 0..<count {
            let t = Double(i) / Double(Dsp.sampleRate)
            noise ^= noise << 13
            noise ^= noise >> 17
            noise ^= noise << 5
            let hiss = (Float(noise >> 8) / Float(1 << 24) - 0.5) * 0.05
            samples[i * 2] = Float(0.12 * sin(2 * .pi * 220 * t) + 0.06 * sin(2 * .pi * 1_375 * t)) + hiss
            samples[i * 2 + 1] = Float(0.10 * sin(2 * .pi * 330 * t) + 0.05 * sin(2 * .pi * 2_000 * t)) + hiss
        }
        return samples
    }
}

/// Plays silence so iOS keeps the app running with the screen locked (the benchmark's stand-in for
/// real playback; Background Modes: audio).
final class SilentAudio {
    private let engine = AVAudioEngine()
    private var running = false

    func start() throws {
        guard !running else { return }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try session.setActive(true)
        let format = engine.outputNode.inputFormat(forBus: 0)
        let source = AVAudioSourceNode(format: format) { _, _, _, buffers in
            for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: format)
        try engine.start()
        running = true
    }

    func stop() {
        guard running else { return }
        engine.stop()
        running = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
