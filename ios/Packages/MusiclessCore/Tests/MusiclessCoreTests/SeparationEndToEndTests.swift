import Foundation
import MusiclessCore
import Testing

/// ios/.fixtures/separation, built by ios/tools/separation_fixture.sh (never committed).
enum LocalFixtures {
    static let separation = LocalModels.directory.deletingLastPathComponent()
        .appendingPathComponent(".fixtures/separation", isDirectory: true)
    static var clip: URL { separation.appendingPathComponent("clip.wav") }
    static var reference: URL { separation.appendingPathComponent("reference_voices.f32") }
    static var available: Bool {
        LocalModels.available && [clip, reference].allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// US-005: 30 s of a CC BY clip through the Swift Separator + ModelRuntime (ONNX Runtime CPU)
/// against ios/tools/reference_two_models.py. The PRD's threshold is 35 dB SNR; the measured value
/// is printed and recorded in docs/ios/DECISIONS.md.
@Suite struct SeparationEndToEndTests {
    static let minimumSNR = 35.0

    @Test(.enabled(if: LocalFixtures.available, "needs ios/.models and ios/.fixtures (ios/tools/separation_fixture.sh)"))
    func swiftMatchesThePythonReference() async throws {
        let input = try Self.readWav(LocalFixtures.clip)
        let reference = try Data(contentsOf: LocalFixtures.reference)
            .withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }

        let runtime = ModelRuntime(models: LocalModels.urls, log: { print($0) })
        let separator = Separator(backend: runtime, log: { print($0) })
        try await separator.configure(sampleRate: 44_100, channels: 2)
        let collector = Task {
            var voices: [Float] = []
            while let chunk = await separator.nextChunk(), !chunk.isEndOfStream { voices += chunk.voices }
            return voices
        }
        let start = ContinuousClock.now
        for offset in stride(from: 0, to: input.count, by: 8_192) {
            await separator.enqueue(Array(input[offset..<min(offset + 8_192, input.count)]))
        }
        await separator.endOfStream()
        let voices = await collector.value
        let elapsed = ContinuousClock.now - start
        await separator.close()

        #expect(voices.count == reference.count)
        var signal = 0.0, noise = 0.0, maxError: Float = 0
        for (a, b) in zip(voices, reference) {
            signal += Double(b) * Double(b)
            noise += Double(a - b) * Double(a - b)
            maxError = max(maxError, abs(a - b))
        }
        let snr = 10 * log10(signal / max(noise, .leastNonzeroMagnitude))
        print(String(format: "End-to-end vs Python reference: SNR %.1f dB, max |error| %.3g, 30 s separated in %.2f s (%@, ORT CPU)",
                     snr, maxError, Double(elapsed / .milliseconds(1)) / 1000, TestPlatform.name))
        #expect(snr >= Self.minimumSNR)
    }

    /// 16-bit PCM WAV -> interleaved Float32 (the `wave` module's plain header).
    static func readWav(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        var at = 12
        while at + 8 <= data.count {
            let tag = String(decoding: data[at..<(at + 4)], as: UTF8.self)
            let size = Int(data[at + 4]) | Int(data[at + 5]) << 8 | Int(data[at + 6]) << 16 | Int(data[at + 7]) << 24
            if tag == "data" {
                return data[(at + 8)..<(at + 8 + size)].withUnsafeBytes { raw in
                    raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32768 }
                }
            }
            at += 8 + size + (size & 1)
        }
        throw SeparatorTestError.injected
    }
}
