import Foundation
import MusiclessCore
import Testing

/// US-003: the Swift DSP against the golden output of Android's unchanged MusiclessDsp.java
/// (ios/tools/dsp-golden). Tolerances from the PRD: spectrum and magnitude within 1e-3 of the
/// reference's peak, synthesis output within 1e-4 absolute. The measured errors are printed and
/// recorded in docs/ios/DECISIONS.md.
@Suite struct DspGoldenTests {
    static let spectrumTolerance: Float = 1e-3   // max |swift - java| / max |java|
    static let magnitudeTolerance: Float = 1e-3
    static let outputTolerance: Float = 1e-4     // max |swift - java|

    @Test(arguments: [64, 512])
    func matchesJava(frames: Int) throws {
        let fixture = try GoldenFixture.load(frames: frames)
        let pcm = GoldenInput.pcm(window: frames * Dsp.hop)
        #expect(GoldenInput.fnv1a(pcm) == fixture.manifest.inputHash,
                "the Swift input generator no longer reproduces the Java one bit for bit")
        let audio = pcm.map { Float($0) / 32768 }

        let dsp = Dsp(frames: frames)
        let analysis = dsp.analyze(audio)
        let output = dsp.synthesize(spectrum: analysis.spectrum, mask: GoldenInput.mask(frames: frames))

        let spectrum = Comparison(fixture.select(spectrum: analysis.spectrum), fixture.spectrum)
        let magnitude = Comparison(fixture.select(magnitude: analysis.magnitude), fixture.magnitude)
        let synthesis = Comparison(fixture.select(output: output), fixture.output)
        print("DSP parity F=\(frames): spectrum \(spectrum), magnitude \(magnitude), output \(synthesis)")

        #expect(spectrum.peakRelative <= Self.spectrumTolerance)
        #expect(magnitude.peakRelative <= Self.magnitudeTolerance)
        #expect(synthesis.maxAbs <= Self.outputTolerance)

        // Whole-array statistics: they cover every frame, including those the F=512 fixture skips.
        let m = fixture.manifest
        #expect(Stats(analysis.spectrum).matches(m.spectrum, sumIsCancelling: true))
        #expect(Stats(analysis.magnitude).matches(m.magnitude, sumIsCancelling: false))
        #expect(Stats(output).matches(m.output, sumIsCancelling: true))
    }
}

// MARK: - The deterministic input (mirror of DspGolden.java's input() and mask())

enum GoldenInput {
    /// Interleaved stereo int16 from integer arithmetic only, bit-identical to the Java generator.
    static func pcm(window: Int) -> [Int16] {
        var table = [Int32](repeating: 0, count: 4096)
        for i in 0..<4096 {
            table[i] = Int32((sin(2 * Double.pi * Double(i) / 4096) * 32767 + 0.5).rounded(.down))
        }
        let increments: [UInt32] = [21_425_000, 133_903_000, 536_870_912, 32_137_000, 194_783_000, 681_706_000]
        let weights: [Int32] = [8, 5, 2]
        var phases = [UInt32](repeating: 0, count: 6)
        var noise: UInt32 = 0x1234_5678
        var pcm = [Int16](repeating: 0, count: window * 2)
        for n in 0..<window {
            for channel in 0..<2 {
                var sample: Int32 = 0
                for j in 0..<3 {
                    let k = channel * 3 + j
                    sample += table[Int(phases[k] >> 20)] * weights[j]
                    phases[k] &+= increments[k]
                }
                noise ^= noise << 13
                noise ^= noise >> 17
                noise ^= noise << 5
                sample = sample / 32 + (Int32((noise >> 16) & 0xFFFF) - 32768) / 16
                pcm[n * 2 + channel] = Int16(truncatingIfNeeded: sample)
            }
        }
        return pcm
    }

    static func mask(frames: Int) -> [Float] {
        var mask = [Float](repeating: 0, count: 2 * frames * Dsp.bins)
        for channel in 0..<2 {
            for f in 0..<frames {
                for k in 0..<Dsp.bins {
                    mask[(channel * frames + f) * Dsp.bins + k] = Float((channel * 7 + f * 13 + k * 31) % 101) / 100
                }
            }
        }
        return mask
    }

    static func fnv1a(_ pcm: [Int16]) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for sample in pcm {
            hash ^= UInt64(UInt16(bitPattern: sample))
            hash &*= 0x0000_0100_0000_01b3
        }
        return String(format: "%016llx", hash)
    }
}

// MARK: - Fixture files

struct GoldenFixture {
    struct Manifest: Decodable {
        let fixtures: [Entry]
    }

    struct Entry: Decodable {
        let frames: Int
        let full: Bool
        let inputHash: String
        let specFrames: [Int]?
        let magnitudeFrames: [Int]?
        let outputRanges: [[Int]]?
        let spec: Stats.Reference
        let magnitude: Stats.Reference
        let output: Stats.Reference

        var spectrum: Stats.Reference { spec }
    }

    let manifest: Entry
    let spectrum: [Float]
    let magnitude: [Float]
    let output: [Float]

    static func load(frames: Int) throws -> GoldenFixture {
        let all = try JSONDecoder().decode(Manifest.self, from: try data("manifest.json"))
        let entry = try #require(all.fixtures.first { $0.frames == frames })
        let prefix = "f\(frames)_"
        return GoldenFixture(manifest: entry,
                             spectrum: floats(try data(prefix + "spec.f32")),
                             magnitude: floats(try data(prefix + "magnitude.f32")),
                             output: floats(try data(prefix + "output.f32")))
    }

    func select(spectrum values: [Float]) -> [Float] {
        guard let picks = manifest.specFrames, !manifest.full else { return values }
        return Self.frames(values, framesPerChannel: manifest.frames + 1, picks: picks, width: 2 * Dsp.bins)
    }

    func select(magnitude values: [Float]) -> [Float] {
        guard let picks = manifest.magnitudeFrames, !manifest.full else { return values }
        return Self.frames(values, framesPerChannel: manifest.frames, picks: picks, width: Dsp.bins)
    }

    func select(output values: [Float]) -> [Float] {
        guard let ranges = manifest.outputRanges, !manifest.full else { return values }
        return ranges.flatMap { values[($0[0] * 2)..<($0[1] * 2)] }
    }

    private static func frames(_ values: [Float], framesPerChannel: Int, picks: [Int], width: Int) -> [Float] {
        var result: [Float] = []
        for channel in 0..<2 {
            for f in picks {
                let start = (channel * framesPerChannel + f) * width
                result += values[start..<(start + width)]
            }
        }
        return result
    }

    private static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/dsp"),
                               "missing fixture \(name); run ios/tools/dsp-golden/run.sh")
        return try Data(contentsOf: url)
    }

    /// Little-endian float32, the byte order of every Apple platform.
    private static func floats(_ data: Data) -> [Float] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}

// MARK: - Measures

struct Comparison: CustomStringConvertible {
    let maxAbs: Float
    let peakRelative: Float
    let normRelative: Double

    init(_ actual: [Float], _ reference: [Float]) {
        precondition(actual.count == reference.count, "\(actual.count) vs \(reference.count) values")
        var maxAbs: Float = 0, peak: Float = 0, error = 0.0, norm = 0.0
        for (a, b) in zip(actual, reference) {
            maxAbs = max(maxAbs, abs(a - b))
            peak = max(peak, abs(b))
            error += Double(a - b) * Double(a - b)
            norm += Double(b) * Double(b)
        }
        self.maxAbs = maxAbs
        peakRelative = peak > 0 ? maxAbs / peak : maxAbs
        normRelative = norm > 0 ? (error / norm).squareRoot() : error.squareRoot()
    }

    var description: String {
        String(format: "maxAbs=%.3g peakRel=%.3g normRel=%.3g", maxAbs, peakRelative, normRelative)
    }
}

struct Stats {
    struct Reference: Decodable {
        let count: Int
        let sum: Double
        let sumSquares: Double
        let maxAbs: Double
    }

    let count: Int
    let sum: Double
    let sumSquares: Double
    let maxAbs: Double

    init(_ values: [Float]) {
        var sum = 0.0, squares = 0.0, maxAbs = 0.0
        for value in values {
            sum += Double(value)
            squares += Double(value) * Double(value)
            maxAbs = max(maxAbs, Double(abs(value)))
        }
        count = values.count
        self.sum = sum
        sumSquares = squares
        self.maxAbs = maxAbs
    }

    /// Energy within 1e-4 and peak within 1e-3 (relative). A sum that cancels to near zero
    /// (spectrum, audio) is compared against the array's RMS scale instead of its own size.
    func matches(_ reference: Reference, sumIsCancelling: Bool) -> Bool {
        let sumScale = sumIsCancelling ? (reference.sumSquares * Double(reference.count)).squareRoot() : abs(reference.sum)
        return count == reference.count
            && abs(sumSquares - reference.sumSquares) <= 1e-4 * reference.sumSquares
            && abs(maxAbs - reference.maxAbs) <= 1e-3 * reference.maxAbs
            && abs(sum - reference.sum) <= 1e-4 * sumScale
    }
}
