import Foundation
import Accelerate

/// Kaldi-compatible 80-bin log-mel filterbank features.
///
/// The speaker-embedding model (WeSpeaker ResNet34) takes `feats [1, T, 80]`,
/// not raw waveform — unlike the VoxLingua language identifier, whose export
/// carries its feature pipeline inside the graph. WeSpeaker was trained on
/// Kaldi's `compute-fbank-feats` output, so this reproduces that arithmetic
/// exactly; an approximation here does not degrade gracefully, it produces
/// embeddings that cluster on the wrong thing.
///
/// Pinned to the settings WeSpeaker trained with (and that sherpa-onnx feeds
/// at inference): 25 ms frames on a 10 ms hop, snip-edges, DC removal, 0.97
/// pre-emphasis, Povey window, power spectrum, 80 mel bins from 20 Hz to
/// Nyquist, natural log. The model's own metadata says `normalize_samples=0`,
/// meaning it expects samples on the int16 scale rather than ±1 — so callers
/// pass ±1 floats and `scaleToInt16` restores the training scale.
///
/// `SpeakerEmbedderSelfTest` pins the pieces (window, mel layout, framing,
/// Parseval on the FFT) against values computed from Kaldi's formulas.
enum Fbank {

    static let sampleRate = 16_000
    static let numBins = 80
    static let frameLength = 400        // 25 ms
    static let frameShift = 160         // 10 ms
    static let fftSize = 512            // next power of two ≥ frameLength
    static let lowFreq: Float = 20
    static let preemphasis: Float = 0.97
    /// Kaldi's `MelBanks` walks bins `0 ..< padded_window_size / 2`, so the
    /// Nyquist bin is deliberately excluded.
    static let numFFTBins = fftSize / 2

    /// Number of frames Kaldi's `snip_edges = true` yields for `n` samples.
    static func frameCount(samples n: Int) -> Int {
        n < frameLength ? 0 : 1 + (n - frameLength) / frameShift
    }

    private static func mel(_ hz: Float) -> Float { 1127 * log(1 + hz / 700) }

    /// `w[i] = (0.5 - 0.5 cos(2πi / (N-1)))^0.85` — Kaldi's "povey" window,
    /// a Hann raised to 0.85.
    static let window: [Float] = {
        let a = 2 * Float.pi / Float(frameLength - 1)
        return (0..<frameLength).map { pow(0.5 - 0.5 * cos(a * Float($0)), 0.85) }
    }()

    /// Triangular mel filters as (firstBin, weights) — Kaldi stores only each
    /// filter's support, which is also what makes the dot product cheap.
    static let filters: [(offset: Int, weights: [Float])] = {
        let nyquist = Float(sampleRate) / 2
        let melLow = mel(lowFreq), melHigh = mel(nyquist)
        let delta = (melHigh - melLow) / Float(numBins + 1)
        let binWidth = Float(sampleRate) / Float(fftSize)
        return (0..<numBins).map { b in
            let left = melLow + Float(b) * delta
            let center = left + delta
            let right = left + 2 * delta
            var offset = -1
            var weights: [Float] = []
            for i in 0..<numFFTBins {
                let m = mel(binWidth * Float(i))
                guard m > left, m < right else {
                    if offset >= 0 && !weights.isEmpty && m >= right { break }
                    continue
                }
                if offset < 0 { offset = i }
                weights.append(m <= center ? (m - left) / (center - left)
                                           : (right - m) / (right - center))
            }
            return (offset < 0 ? 0 : offset, weights)
        }
    }()

    private static let fftSetup: FFTSetup = vDSP_create_fftsetup(
        vDSP_Length(log2(Double(fftSize))), FFTRadix(kFFTRadix2))!

    /// Log-mel features for `samples` (±1 floats, 16 kHz mono), row-major
    /// `[T][80]` flattened. Returns nil when there is not a single full frame.
    ///
    /// `subtractMean` applies the per-utterance cepstral mean normalization
    /// WeSpeaker expects at inference: every bin is centred over time, which
    /// is what removes the channel/room term the embedding must not encode.
    static func features(_ samples: [Float],
                         scaleToInt16: Bool = true,
                         subtractMean: Bool = true) -> (values: [Float], frames: Int)? {
        let frames = frameCount(samples: samples.count)
        guard frames > 0 else { return nil }

        var out = [Float](repeating: 0, count: frames * numBins)
        var frame = [Float](repeating: 0, count: frameLength)
        var padded = [Float](repeating: 0, count: fftSize)
        var real = [Float](repeating: 0, count: fftSize / 2)
        var imag = [Float](repeating: 0, count: fftSize / 2)
        var power = [Float](repeating: 0, count: numFFTBins)
        let scale: Float = scaleToInt16 ? 32768 : 1

        for f in 0..<frames {
            let start = f * frameShift
            for i in 0..<frameLength { frame[i] = samples[start + i] * scale }

            // Kaldi's ProcessWindow order: remove DC, pre-emphasize, window.
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(frameLength))
            var negMean = -mean
            vDSP_vsadd(frame, 1, &negMean, &frame, 1, vDSP_Length(frameLength))
            for i in stride(from: frameLength - 1, through: 1, by: -1) {
                frame[i] -= preemphasis * frame[i - 1]
            }
            frame[0] -= preemphasis * frame[0]
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(frameLength))

            for i in 0..<frameLength { padded[i] = frame[i] }
            for i in frameLength..<fftSize { padded[i] = 0 }

            // Real-to-complex FFT. vDSP's packed format puts Nyquist in
            // imag[0] and returns values scaled by 2, hence the 0.5 below.
            real.withUnsafeMutableBufferPointer { rp in
                imag.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!,
                                                imagp: ip.baseAddress!)
                    padded.withUnsafeBufferPointer { pp in
                        pp.baseAddress!.withMemoryRebound(
                            to: DSPComplex.self, capacity: fftSize / 2) { cp in
                            vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(fftSize / 2))
                        }
                    }
                    vDSP_fft_zrip(fftSetup, &split, 1,
                                  vDSP_Length(log2(Double(fftSize))), FFTDirection(FFT_FORWARD))
                }
            }
            // Bin 0 is DC (imag[0] holds Nyquist, which Kaldi's mel layout
            // never reads); bins 1 ..< 256 are ordinary complex pairs.
            power[0] = real[0] * 0.5 * (real[0] * 0.5)
            for k in 1..<numFFTBins {
                let re = real[k] * 0.5, im = imag[k] * 0.5
                power[k] = re * re + im * im
            }

            let row = f * numBins
            for (b, filt) in filters.enumerated() {
                var energy: Float = 0
                let n = min(filt.weights.count, numFFTBins - filt.offset)
                if n > 0 {
                    power.withUnsafeBufferPointer { pp in
                        filt.weights.withUnsafeBufferPointer { wp in
                            vDSP_dotpr(pp.baseAddress! + filt.offset, 1,
                                       wp.baseAddress!, 1, &energy, vDSP_Length(n))
                        }
                    }
                }
                out[row + b] = log(max(energy, .leastNormalMagnitude))
            }
        }

        if subtractMean, frames > 1 {
            for b in 0..<numBins {
                var sum: Float = 0
                for f in 0..<frames { sum += out[f * numBins + b] }
                let m = sum / Float(frames)
                for f in 0..<frames { out[f * numBins + b] -= m }
            }
        }
        return (out, frames)
    }
}
