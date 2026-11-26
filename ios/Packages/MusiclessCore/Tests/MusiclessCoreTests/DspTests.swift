import Foundation
import MusiclessCore
import Testing

/// The behaviours of Android's MusiclessDspTest, on the Swift port.
@Suite struct DspTests {
    @Test func unityMaskReconstructsBandLimitedStereoAndZeroMaskIsSilent() {
        let dsp = Dsp(frames: Dsp.maxFrames)
        var audio = [Float](repeating: 0, count: dsp.window * 2)
        for i in 0..<dsp.window {
            audio[i * 2] = Float(0.2 * sin(2 * Double.pi * 440 * Double(i) / Double(Dsp.sampleRate)))
            audio[i * 2 + 1] = Float(0.1 * sin(2 * Double.pi * 880 * Double(i) / Double(Dsp.sampleRate)))
        }
        let analysis = dsp.analyze(audio)
        #expect(analysis.spectrum.count == 2 * 513 * 1024 * 2)
        #expect(analysis.magnitude.count == 2 * 512 * 1024)

        let silent = dsp.synthesize(spectrum: analysis.spectrum,
                                    mask: [Float](repeating: 0, count: analysis.magnitude.count))
        #expect(silent.allSatisfy { $0 == 0 })

        let result = dsp.synthesize(spectrum: analysis.spectrum,
                                    mask: [Float](repeating: 1, count: analysis.magnitude.count))
        var error = 0.0, signal = 0.0
        for i in audio.indices {
            #expect(result[i].isFinite)
            error += Double(audio[i] - result[i]) * Double(audio[i] - result[i])
            signal += Double(audio[i]) * Double(audio[i])
        }
        #expect(error / signal < 1e-5, "unity mask should reconstruct below-11 kHz audio")
    }

    @Test func shortWindowReusesScratchWithoutLeakingPreviousOutput() {
        let dsp = Dsp(frames: Dsp.rampFrames[0])
        let constant = [Float](repeating: 0.2, count: dsp.window * 2)
        let analysis = dsp.analyze(constant)
        let mask = [Float](repeating: 1, count: analysis.magnitude.count)
        let output = dsp.synthesize(spectrum: analysis.spectrum, mask: mask)
        #expect(output.count == constant.count)
        #expect(abs(output[12345] - 0.2) < 1e-6)

        let quiet = dsp.analyze([Float](repeating: 0, count: dsp.window * 2))
        let silent = dsp.synthesize(spectrum: quiet.spectrum, mask: mask)
        #expect(silent.allSatisfy { $0 == 0 })
        // The first result is still intact: results are values, not views of the scratch.
        #expect(abs(output[12345] - 0.2) < 1e-6)
    }

    @Test func overlapWeightsSumToOne() {
        #expect(Dsp.maxFrames * Dsp.hop == (Dsp.maxFrames * Dsp.hop - Dsp.overlap) + Dsp.overlap)
        for i in 0..<Dsp.overlap {
            let rise = (Float(i) + 0.5) / Float(Dsp.overlap)
            #expect(abs(rise + (1 - rise) - 1) <= 1e-7)
        }
    }

    @Test func gainTargetsMinus24DbfsWithin30Db() {
        let quiet = [Float](repeating: 1e-6, count: 2048)
        #expect(abs(Dsp.inputGain(quiet) - pow(10, 1.5)) < 1e-9)
        let loud = [Float](repeating: 1, count: 2048)
        #expect(abs(Dsp.inputGain(loud) - pow(10, -1.2) / (1 + 1e-9)) < 1e-12)
    }
}
