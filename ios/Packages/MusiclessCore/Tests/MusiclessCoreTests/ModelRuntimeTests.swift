import Foundation
import MusiclessCore
import Testing

extension LocalModels {
    /// The real release models, downloaded by `MUSICLESS_LIVE_MODELS=1 swift test --filter liveRelease`.
    static var urls: [URL] {
        ModelFile.spleeter.map { directory.appendingPathComponent("\($0.sha256)-\($0.name)") }
    }

    static var available: Bool { urls.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } }
}

/// US-005's model holder, mirroring Android's MusiclessModelHolderTest where it applies.
@Suite struct ModelRuntimeTests {
    static func energy(_ samples: [Float]) -> Double {
        var sum = 0.0
        for sample in samples { sum += Double(sample) * Double(sample) }
        return sum
    }

    @Test func idleReleaseDefaultsToTwoMinutes() {
        #expect(ModelRuntime.defaultIdleRelease == .seconds(120))
    }

    @Test func passThroughSkipsTheModels() async throws {
        let missing = [URL(fileURLWithPath: "/nonexistent/vocals.onnx"), URL(fileURLWithPath: "/nonexistent/accompaniment.onnx")]
        let runtime = ModelRuntime(models: missing)
        let block = (0..<(64 * Dsp.hop * 2)).map { Float($0 % 7) / 7 }
        let result = try await runtime.separate(block, passThrough: true, submittedAt: .now)
        #expect(result.voices == block)
        #expect(await runtime.isLoaded == false)
    }

    @Test func missingModelFailsWithoutCrashing() async {
        let missing = [URL(fileURLWithPath: "/nonexistent/vocals.onnx"), URL(fileURLWithPath: "/nonexistent/accompaniment.onnx")]
        let runtime = ModelRuntime(models: missing)
        await #expect(throws: OnnxError.self) { try await runtime.load() }
        #expect(await runtime.isLoaded == false)
    }

    @Test(.enabled(if: LocalModels.available, "needs ios/.models (see ModelStoreTests.liveRelease)"))
    func realModelsSeparateBothWindowSizes() async throws {
        let runtime = ModelRuntime(models: LocalModels.urls, log: { print($0) })
        for frames in [64, 512] {
            let block = GoldenInput.pcm(window: frames * Dsp.hop).map { Float($0) / 32768 }
            let result = try await runtime.separate(block, passThrough: false, submittedAt: .now)
            #expect(result.voices.count == block.count)
            #expect(result.voices.allSatisfy { $0.isFinite })
            // A mask in [0, 1] can only remove energy (up to the DSP's float error).
            let voicesEnergy = Self.energy(result.voices), inputEnergy = Self.energy(block)
            #expect(voicesEnergy <= inputEnergy * 1.001)
            print("ORT CPU (\(TestPlatform.name)) F=\(frames): pipelineMs=\(result.timings.pipelineMs) \(result.timings.logFields)")
        }
    }

    @Test(.enabled(if: LocalModels.available, "needs ios/.models"))
    func sessionsSurviveUntilTheLastUserLeavesAndTheIdleTimerExpires() async throws {
        let runtime = ModelRuntime(models: LocalModels.urls, idleRelease: .milliseconds(200))
        await runtime.acquire()
        await runtime.acquire()
        try await runtime.load()
        await runtime.release()
        try await Task.sleep(for: .milliseconds(400))
        #expect(await runtime.isLoaded, "one user left")
        await runtime.release()
        #expect(await runtime.isLoaded, "the idle timer hasn't run yet")
        try await Task.sleep(for: .milliseconds(400))
        #expect(await runtime.isLoaded == false)
    }

    @Test(.enabled(if: LocalModels.available, "needs ios/.models"))
    func reuseInvalidatesThePreviousIdleRelease() async throws {
        let runtime = ModelRuntime(models: LocalModels.urls, idleRelease: .milliseconds(200))
        await runtime.acquire()
        try await runtime.load()
        await runtime.release()
        await runtime.acquire()
        try await Task.sleep(for: .milliseconds(400))
        #expect(await runtime.isLoaded)
        await runtime.release()
        try await Task.sleep(for: .milliseconds(400))
        #expect(await runtime.isLoaded == false)
    }

    @Test(.enabled(if: LocalModels.available, "needs ios/.models"))
    func memoryWarningReleasesOnlyIdleSessions() async throws {
        let runtime = ModelRuntime(models: LocalModels.urls)
        await runtime.acquire()
        try await runtime.load()
        await runtime.didReceiveMemoryWarning()
        #expect(await runtime.isLoaded, "a player is using them")
        await runtime.release()
        await runtime.didReceiveMemoryWarning()
        #expect(await runtime.isLoaded == false)
    }
}
