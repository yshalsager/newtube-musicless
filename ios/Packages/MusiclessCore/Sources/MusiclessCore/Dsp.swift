import Accelerate

/// Spleeter's STFT / ISTFT around the voice mask: a port of Android's `MusiclessDsp.java`
/// (PRD §4.3; the Java code is the authority). One instance per window size; it owns its scratch,
/// so it is not thread-safe: use it from one executor.
///
/// Layouts (identical to Java):
/// - audio and output: interleaved stereo, `frames * hop` samples per channel;
/// - spectrum: `[channel][frame 0...frames][bin < bins]` as interleaved complex (re, im);
/// - magnitude and mask: `[channel][frame < frames][bin < bins]`, the model's `[2, 1, frames, 1024]`.
public final class Dsp {
    public static let sampleRate = 44_100
    public static let fftSize = 4096
    public static let hop = 1024
    public static let bins = 1024
    public static let maxFrames = 512
    /// Samples shared by neighbouring windows (each window re-reads the previous window's last 2048).
    public static let overlap = 2 * hop
    /// Window sizes after every start, seek or flush; 512 repeats after the ramp.
    public static let rampFrames = [64, 128, 256, 512]

    public struct Analysis {
        /// Complex spectrum, kept for synthesis: `2 * (frames + 1) * bins * 2` floats.
        public var spectrum: [Float]
        /// Model input: `|X| * gain`, `2 * frames * bins` floats.
        public var magnitude: [Float]
    }

    public let frames: Int
    /// Samples per channel.
    public let window: Int

    private static let log2n = vDSP_Length(12)
    private static let half = fftSize / 2
    private let setup: FFTSetup
    private let hann: UnsafeMutablePointer<Float>
    /// Hann / fftSize: the synthesis window with the inverse FFT's normalisation folded in.
    private let synthesisWindow: UnsafeMutablePointer<Float>
    /// 1 / Σ hann² at each output sample (1 where the sum is ~0), as Java divides by it.
    private let inverseWeight: UnsafeMutablePointer<Float>
    private let real: UnsafeMutablePointer<Float>
    private let imag: UnsafeMutablePointer<Float>
    private let frame: UnsafeMutablePointer<Float>
    private var spectrumScratch: [Float]
    private var magnitudeScratch: [Float]
    private var output: [Float]

    public init(frames: Int) {
        precondition(frames > 0 && frames <= Dsp.maxFrames, "frames must be in 1...\(Dsp.maxFrames)")
        self.frames = frames
        let window = frames * Dsp.hop  // a local, so the closures below don't capture self early
        self.window = window
        guard let setup = vDSP_create_fftsetup(Dsp.log2n, FFTRadix(kFFTRadix2)) else {
            fatalError("vDSP_create_fftsetup failed")
        }
        self.setup = setup
        let n = Dsp.fftSize
        hann = .allocate(capacity: n)
        synthesisWindow = .allocate(capacity: n)
        real = .allocate(capacity: Dsp.half)
        imag = .allocate(capacity: Dsp.half)
        frame = .allocate(capacity: n)
        let inverseWeight = UnsafeMutablePointer<Float>.allocate(capacity: window)
        self.inverseWeight = inverseWeight

        var hannDouble = [Double](repeating: 0, count: n)
        for i in 0..<n {
            hannDouble[i] = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n))
            hann[i] = Float(hannDouble[i])
            synthesisWindow[i] = Float(hannDouble[i] / Double(n))
        }
        // Σ hann² over the frames covering each sample, one vector add per frame (this runs for every
        // ramp window, on the path to the first voices).
        let hannSquared = hannDouble.map { $0 * $0 }
        var weight = [Double](repeating: 0, count: window)
        weight.withUnsafeMutableBufferPointer { weight in
            hannSquared.withUnsafeBufferPointer { squares in
                for f in 0...frames {
                    let start = f * Dsp.hop - Dsp.half
                    let low = max(0, start), high = min(window, start + n)
                    guard low < high else { continue }
                    let target = weight.baseAddress! + low
                    vDSP_vaddD(target, 1, squares.baseAddress! + (low - start), 1, target, 1, vDSP_Length(high - low))
                }
                for i in 0..<window where weight[i] <= 1e-11 { weight[i] = 1 }
                var one = 1.0
                vDSP_svdivD(&one, weight.baseAddress!, 1, weight.baseAddress!, 1, vDSP_Length(window))
                vDSP_vdpsp(weight.baseAddress!, 1, inverseWeight, 1, vDSP_Length(window))
            }
        }

        spectrumScratch = [Float](repeating: 0, count: 2 * (frames + 1) * Dsp.bins * 2)
        magnitudeScratch = [Float](repeating: 0, count: 2 * frames * Dsp.bins)
        output = [Float](repeating: 0, count: window * 2)
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
        for pointer in [hann, synthesisWindow, inverseWeight, real, imag, frame] { pointer.deallocate() }
    }

    // MARK: Analysis

    /// `audio`: `window` interleaved stereo frames. The result stays valid until the next call
    /// only if the caller doesn't keep it (it shares storage with the scratch, copy-on-write).
    public func analyze(_ audio: [Float]) -> Analysis {
        precondition(audio.count == window * 2, "expected \(window * 2) samples, got \(audio.count)")
        let gain = Float(Dsp.inputGain(audio))
        audio.withUnsafeBufferPointer { input in
            spectrumScratch.withUnsafeMutableBufferPointer { spectrum in
                magnitudeScratch.withUnsafeMutableBufferPointer { magnitude in
                    for channel in 0..<2 {
                        for f in 0...frames {
                            loadFrame(input.baseAddress!, channel: channel, frame: f)
                            var split = DSPSplitComplex(realp: real, imagp: imag)
                            vDSP_fft_zrip(setup, &split, 1, Dsp.log2n, FFTDirection(kFFTDirection_Forward))
                            store(channel: channel, frame: f, gain: gain,
                                  spectrum: spectrum.baseAddress!, magnitude: magnitude.baseAddress!)
                        }
                    }
                }
            }
        }
        return Analysis(spectrum: spectrumScratch, magnitude: magnitudeScratch)
    }

    /// The model sees each window at -24 dBFS RMS, with at most 30 dB of gain either way.
    /// Squares in Float, summed in Double, as Java does.
    public static func inputGain(_ audio: [Float]) -> Double {
        var sum = 0.0
        audio.withUnsafeBufferPointer { samples in
            for sample in samples { sum += Double(sample * sample) }
        }
        let rms = (sum / Double(audio.count)).squareRoot()
        return max(pow(10, -1.5), min(pow(10, 1.5), pow(10, -1.2) / (rms + 1e-9)))
    }

    /// Windows one centred, reflect-padded frame of one channel into `real` / `imag` in vDSP's
    /// even/odd split layout (sample 2i -> real[i], 2i + 1 -> imag[i]).
    private func loadFrame(_ audio: UnsafePointer<Float>, channel: Int, frame f: Int) {
        let n = Dsp.fftSize, start = f * Dsp.hop - Dsp.half
        if start >= 0 && start + n <= window {
            let base = audio + start * 2 + channel
            vDSP_vmul(base, 4, hann, 2, real, 1, vDSP_Length(Dsp.half))
            vDSP_vmul(base + 2, 4, hann + 1, 2, imag, 1, vDSP_Length(Dsp.half))
            return
        }
        for i in 0..<n {
            var at = start + i
            at = at < 0 ? -at : at >= window ? 2 * (window - 1) - at : at
            frame[i] = audio[at * 2 + channel] * hann[i]
        }
        for i in 0..<Dsp.half {
            real[i] = frame[2 * i]
            imag[i] = frame[2 * i + 1]
        }
    }

    /// vDSP's forward real FFT returns twice the DFT, with the Nyquist value in imag[0].
    private func store(channel: Int, frame f: Int, gain: Float,
                       spectrum: UnsafeMutablePointer<Float>, magnitude: UnsafeMutablePointer<Float>) {
        let bins = vDSP_Length(Dsp.bins)
        var half: Float = 0.5
        vDSP_vsmul(real, 1, &half, real, 1, bins)
        vDSP_vsmul(imag, 1, &half, imag, 1, bins)
        imag[0] = 0  // DC is real; imag[0] held the Nyquist bin, which isn't kept
        var split = DSPSplitComplex(realp: real, imagp: imag)
        let row = (channel * (frames + 1) + f) * Dsp.bins
        spectrum.advanced(by: row * 2).withMemoryRebound(to: DSPComplex.self, capacity: Dsp.bins) {
            vDSP_ztoc(&split, 1, $0, 2, bins)
        }
        guard f < frames else { return }  // the last frame is not model input
        let target = magnitude + (channel * frames + f) * Dsp.bins
        vDSP_zvabs(&split, 1, target, 1, bins)
        var scale = gain
        vDSP_vsmul(target, 1, &scale, target, 1, bins)
    }

    // MARK: Synthesis

    /// Masks the spectrum (bins >= 1024 zeroed, a ~11 kHz low-pass as on Android), inverts each
    /// frame, and overlap-adds with Hann² normalisation. `mask` has the magnitude's layout; the
    /// last spectrum frame reuses the previous frame's mask.
    public func synthesize(spectrum: [Float], mask: [Float]) -> [Float] {
        precondition(spectrum.count == spectrumScratch.count && mask.count == magnitudeScratch.count)
        let bins = vDSP_Length(Dsp.bins), upper = vDSP_Length(Dsp.half - Dsp.bins)
        spectrum.withUnsafeBufferPointer { spectrum in
            mask.withUnsafeBufferPointer { mask in
                output.withUnsafeMutableBufferPointer { output in
                    let out = output.baseAddress!
                    vDSP_vclr(out, 1, vDSP_Length(output.count))
                    for channel in 0..<2 {
                        for f in 0...frames {
                            let row = (channel * (frames + 1) + f) * Dsp.bins
                            var split = DSPSplitComplex(realp: real, imagp: imag)
                            spectrum.baseAddress!.advanced(by: row * 2)
                                .withMemoryRebound(to: DSPComplex.self, capacity: Dsp.bins) {
                                    vDSP_ctoz($0, 2, &split, 1, bins)
                                }
                            let gains = mask.baseAddress! + (channel * frames + min(f, frames - 1)) * Dsp.bins
                            vDSP_vmul(real, 1, gains, 1, real, 1, bins)
                            vDSP_vmul(imag, 1, gains, 1, imag, 1, bins)
                            vDSP_vclr(real + Dsp.bins, 1, upper)
                            vDSP_vclr(imag + Dsp.bins, 1, upper)
                            imag[0] = 0  // the Nyquist bin, packed in imag[0], is zero
                            // With true DFT values packed in, the inverse returns the unnormalised IDFT;
                            // synthesisWindow folds in Java's / fftSize.
                            vDSP_fft_zrip(setup, &split, 1, Dsp.log2n, FFTDirection(kFFTDirection_Inverse))
                            overlapAdd(into: out, channel: channel, frame: f)
                        }
                    }
                    for channel in 0..<2 {
                        vDSP_vmul(out + channel, 2, inverseWeight, 1, out + channel, 2, vDSP_Length(window))
                    }
                }
            }
        }
        return output
    }

    private func overlapAdd(into out: UnsafeMutablePointer<Float>, channel: Int, frame f: Int) {
        let n = Dsp.fftSize, start = f * Dsp.hop - Dsp.half
        if start >= 0 && start + n <= window {
            let even = out + start * 2 + channel, odd = even + 2
            vDSP_vma(real, 1, synthesisWindow, 2, even, 4, even, 4, vDSP_Length(Dsp.half))
            vDSP_vma(imag, 1, synthesisWindow + 1, 2, odd, 4, odd, 4, vDSP_Length(Dsp.half))
            return
        }
        for i in 0..<n {
            let at = start + i
            guard at >= 0 && at < window else { continue }
            let sample = i % 2 == 0 ? real[i / 2] : imag[i / 2]
            out[at * 2 + channel] += sample * synthesisWindow[i]
        }
    }
}
