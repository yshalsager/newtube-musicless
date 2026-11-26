import Foundation
import MusiclessCore
import Testing

/// US-003: analyze and synthesize time for a full F = 512 window on this Mac. Meaningful numbers
/// need an optimised build: `swift test -c release --filter DspBenchmark`. The phone's figures come
/// from US-006, not from here.
@Suite struct DspBenchmarkTests {
    @Test func fullWindowTiming() {
        let dsp = Dsp(frames: Dsp.maxFrames)
        var audio = [Float](repeating: 0, count: dsp.window * 2)
        for i in audio.indices { audio[i] = Float(0.2 * sin(Double(i) * 0.03)) }
        let mask = [Float](repeating: 1, count: 2 * Dsp.maxFrames * Dsp.bins)

        var analyze: [Double] = [], synthesize: [Double] = []
        let clock = ContinuousClock()
        for run in 0..<12 {
            var analysis: Dsp.Analysis?
            let a = clock.measure { analysis = dsp.analyze(audio) }
            var output: [Float] = []
            let s = clock.measure { output = dsp.synthesize(spectrum: analysis!.spectrum, mask: mask) }
            #expect(abs(output[1234] - audio[1234]) < 1e-3)
            if run >= 3 {  // three warm-up runs
                analyze.append(a / .milliseconds(1))
                synthesize.append(s / .milliseconds(1))
            }
        }
        let median = { (values: [Double]) in values.sorted()[values.count / 2] }
        #if DEBUG
        let build = "debug build: Swift loops unoptimised"
        #else
        let build = "release build"
        #endif
        print(String(format: "DSP benchmark F=512 (%@, 9 windows after 3 warm-up): analyze median %.2f ms, synthesize median %.2f ms",
                     build, median(analyze), median(synthesize)))
    }
}
