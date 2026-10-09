import Accelerate
import Foundation

/// Cancels speaker echo out of the "Me" track after the call, using the
/// "Participants" track — what the speakers were fed — as the reference.
///
/// `MicCapture`'s voice processing is meant to do this live, and through the
/// MacBook's own speakers it does (measured 2026-10-06: −34.5 dBFS of echo on
/// the raw RØDE, −49 voice-processed). Through the **built-in headphone jack**
/// it does not: macOS treats that port as headphones, switches echo
/// cancellation off and keeps its automatic gain on, so desk speakers plugged
/// into the jack came back *14 dB louder* than the raw mic heard them (−24
/// against −38.5). That is the 2026-10-05 Zoom call: far end at −27 dBFS on
/// the Me track all call, the text-level `EchoSuppressor` dropping 206 segments
/// and still leaving 293 of the other person's words under "Me". Nothing in
/// the voice-processing unit can be asked to cancel there — its extra
/// channels are copies of channel 0, not a reference, and an aggregate device
/// wrapping the jack makes it deliver no audio at all — so the recorder takes
/// the raw mic on that route (`OutputRoute`) and this cancels the echo instead.
///
/// The method is the standard one: a partitioned-block frequency-domain NLMS
/// filter (16 × 256 taps, 256 ms at 16 kHz) whose step shrinks when the error
/// is mostly not echo, so the user talking over the far end slows adaptation
/// instead of teaching the filter their own voice. Measured on the raw RØDE
/// with the far end on the jack speakers: echo −52 → −67 dBFS, no far-end
/// window left above `WavLevel.activeThreshold`, and a voice mixed in over the
/// far end came out at +0.0 dB with correlation 1.00. On calls that never had
/// echo it is a no-op (≤0.16 dB change on the 2026-09-15 and 09-29 calls).
///
/// What it deliberately does **not** do is suppress the residual spectrally.
/// Tried on the voice-processed 10-05 track (whose AGC makes the echo path
/// non-linear, capping the linear filter at ~8 dB): a Wiener-style suppressor
/// took the echo to −60 dBFS, and whisper then wrote sentences nobody said
/// out of its artefacts ("I can't say anything. I think you called the right
/// time.") and lost some of the user's own words spoken over the far end.
/// Residual echo is `EchoSuppressor`'s job, which reads text and cannot invent.
///
/// Offline has two advantages over a live canceller, and both are used. It
/// can **look ahead**: the mic is delayed so the echo lands `centreMs` into the
/// filter whichever track the recorder's host-clock alignment put first (the
/// raw tap's echo arrives 37 ms *before* its reference; voice-processed, ~2 ms
/// after). And it can **start converged**: a first pass over the opening
/// minutes learns the room, and the real pass starts from that filter, so the
/// call's first sentences are not the price of adaptation.
///
/// Pure over `Track`s and covered by `selftest`; `process` is the file wrapper.
enum EchoCanceller {

    static let sampleRate = 16_000
    static let blockSize = 256
    static let partitions = 16
    /// Where the echo's direct path should sit inside the 256 ms filter. Leaves
    /// ~96 ms for the two clocks to drift one way (measured −0.35 ms/min on the
    /// 10-05 call: −20 ms by its end) and ~100 ms the other, past a room tail.
    static let centreMs = 96
    /// Full NLMS step. Half a step left the opening 20 s of the 2026-10-06
    /// jack test at −54 dBFS against −64 — the opening's echo path differs
    /// from the rest (the speakers' amp settling), and only a fast filter
    /// re-learns it in time. The one divergence seen in testing needed this
    /// *and* a 512 ms filter; `divergedBlocks` resets it if it happens anyway.
    static let muMax: Float = 1.0
    /// The opening stretch the warm-up pass learns the room from.
    static let warmupSeconds = 300
    /// Reference loud enough that its echo is worth counting: −60 dBFS.
    static let referenceActiveRMS: Float = 0.001
    /// The cancelled track replaces the recording only when what echo is left
    /// is this quiet (median over echo blocks, dBFS) — below whisper's speech
    /// splice (`AudioStitcher` voice threshold, −54) give or take.
    ///
    /// **Half-cancelling is worse than not cancelling.** On the voice-processed
    /// 10-05 call the filter took ~7 dB (the AGC makes that echo non-linear),
    /// leaving it at −37 dBFS: still words to whisper, but no longer duplicated
    /// often enough for `EchoSuppressor` to engage (25%). The transcript came
    /// back with 1 186 of the other person's words under "Me", against 293
    /// from the recording as it was. A track the filter cannot make quiet is
    /// transcribed as recorded and left to the text guard.
    static let maxResidualDBFS = -50.0
    /// And it must actually have done something.
    static let minUsefulReductionDB = 3.0
    /// Echo blocks needed before any verdict: 2 s.
    static let minEchoBlocks = 125
    /// A block counts as echo when the filter's own estimate is at least this
    /// share of what the mic heard (and the mic heard something above −70 dBFS
    /// — voice processing zeroes the mic outright while the far end talks).
    static let echoShare: Float = 0.25
    static let micAudibleRMS: Float = 0.000316
    /// A filter whose echo estimate runs 20 dB above everything the mic heard
    /// for this long has diverged and starts over: 2 s of blocks.
    static let divergedBlocks = 125

    struct Stats: Equatable {
        /// Echo removed, over the echo blocks (where the filter's estimate was
        /// a real share of what the mic heard — not the user talking over it).
        var reductionDB: Double
        /// What is left there: median block level, dBFS. nil without echo.
        var residualDBFS: Double?
        /// How much of the call carried echo, seconds.
        var echoSeconds: Double
        /// How far the mic lags the reference, ms (negative: it leads). nil
        /// when no echo path stood out — headphones, or a silent far end.
        var lagMs: Double?
        /// Times the filter diverged and was reset.
        var resets: Int

        /// An echo path stood out of the cross-correlation, and the filter
        /// found enough of it to judge. (Echo blocks alone are not evidence: a
        /// filter with nothing to learn still produces the odd estimate that
        /// counts as one — 3–7 min of them on the clean 09-15/09-29 calls.)
        var hadEcho: Bool {
            lagMs != nil
                && echoSeconds * Double(EchoCanceller.sampleRate) / Double(EchoCanceller.blockSize)
                    >= Double(EchoCanceller.minEchoBlocks)
        }
        /// Replace the recording with the cancelled track for transcription.
        var worthApplying: Bool {
            hadEcho && reductionDB >= EchoCanceller.minUsefulReductionDB
                && (residualDBFS ?? 0) <= EchoCanceller.maxResidualDBFS
        }
    }

    /// Read-only sample access, zero outside `0..<count`, so delays need no
    /// padded copies of an hour of audio.
    struct Track {
        let count: Int
        let read: (_ start: Int, _ n: Int, _ into: UnsafeMutablePointer<Float>) -> Void

        static func floats(_ a: [Float]) -> Track {
            Track(count: a.count) { start, n, into in
                for i in 0..<n {
                    let j = start + i
                    into[i] = j >= 0 && j < a.count ? a[j] : 0
                }
            }
        }

        /// 16-bit little-endian PCM, as `AudioStitcher.readPCM` returns it.
        static func pcm16(_ d: Data) -> Track {
            let count = d.count / 2
            return Track(count: count) { start, n, into in
                d.withUnsafeBytes { raw in
                    for i in 0..<n {
                        let j = start + i
                        into[i] = j >= 0 && j < count
                            ? Float(raw.loadUnaligned(fromByteOffset: j * 2, as: Int16.self)) / 32768
                            : 0
                    }
                }
            }
        }
    }

    // MARK: - Files

    /// Cancels `reference`'s echo out of `mic` and writes the result to `out`
    /// (16 kHz mono 16-bit, the same length as `mic`). nil when either track
    /// cannot be read.
    static func process(mic: URL, reference: URL, to out: URL) -> Stats? {
        guard let micPCM = try? AudioStitcher.readPCM(mic),
              let refPCM = try? AudioStitcher.readPCM(reference),
              micPCM.count >= 2, refPCM.count >= 2 else { return nil }
        var pcm = Data(capacity: micPCM.count)
        let stats = cancel(mic: .pcm16(micPCM), reference: .pcm16(refPCM)) { block, n in
            var ints = [Int16](repeating: 0, count: n)
            for i in 0..<n {
                ints[i] = Int16(max(-32768, min(32767, (block[i] * 32768).rounded())))
            }
            ints.withUnsafeBytes { pcm.append(contentsOf: $0) }
        }
        guard (try? AudioStitcher.writeWAV(pcm, to: out, sampleRate: sampleRate)) != nil
        else { return nil }
        return stats
    }

    /// "−18.4 dB over 12.3 min of echo, left at −61 dBFS, echo path −40 ms".
    static func describe(_ s: Stats) -> String {
        var parts = [String(format: "%.1f dB over %.1f min of echo", -s.reductionDB, s.echoSeconds / 60)]
        if let r = s.residualDBFS { parts.append(String(format: "left at %.0f dBFS", r)) }
        if let lag = s.lagMs { parts.append(String(format: "echo path %+.0f ms", lag)) }
        if s.resets > 0 { parts.append("\(s.resets) reset(s)") }
        return parts.joined(separator: ", ")
    }

    // MARK: - Core

    /// Runs the canceller and hands the cleaned mic to `emit` in order, block
    /// by block — exactly `mic.count` samples in all.
    static func cancel(mic: Track, reference: Track,
                       emit: (UnsafePointer<Float>, Int) -> Void) -> Stats {
        let lag = estimateLag(mic: mic, reference: reference)
        // Delay whichever track is early so the echo's direct path lands
        // `centreMs` into the filter.
        // Both tracks are delayed by the same extra amount so the mic's delay
        // falls on a block boundary: each output block is then exactly one
        // processing block, and "never louder than the mic" holds per block
        // of the output rather than only per block of the filter.
        let shift = centreMs * sampleRate / 1000 - (lag ?? 0)
        let micDelay = (max(0, shift) + blockSize - 1) / blockSize * blockSize
        let refDelay = micDelay - shift

        let filter = Filter(blockSize: blockSize, partitions: partitions)
        let warmup = min(mic.count, warmupSeconds * sampleRate)
        _ = filter.run(mic: mic, reference: reference, micDelay: micDelay,
                       refDelay: refDelay, length: warmup, emit: nil)
        filter.restartStream()
        let pass = withoutActuallyEscaping(emit) { emit in
            filter.run(mic: mic, reference: reference, micDelay: micDelay,
                       refDelay: refDelay, length: mic.count, emit: emit)
        }

        let reduction = pass.echoOut > 0 && pass.echoIn > 0 ? 10 * log10(pass.echoIn / pass.echoOut) : 0
        var residual: Double? = nil
        if !pass.residualDB.isEmpty {
            let sorted = pass.residualDB.sorted()
            residual = Double(sorted[sorted.count / 2])
        }
        return Stats(reductionDB: reduction, residualDBFS: residual,
                     echoSeconds: Double(pass.residualDB.count * blockSize) / Double(sampleRate),
                     lagMs: lag.map { Double($0) * 1000 / Double(sampleRate) },
                     resets: pass.resets)
    }

    /// Convenience for tests: whole arrays in, whole array out.
    static func cancel(mic: [Float], reference: [Float]) -> (out: [Float], stats: Stats) {
        var out: [Float] = []
        out.reserveCapacity(mic.count)
        let stats = cancel(mic: .floats(mic), reference: .floats(reference)) { p, n in
            out.append(contentsOf: UnsafeBufferPointer(start: p, count: n))
        }
        return (out, stats)
    }

    /// How many samples the mic's copy of the reference trails it by
    /// (negative: the mic is ahead), from a phase-transform cross-correlation
    /// averaged over the opening minutes' far-end speech. nil when no lag
    /// stands out from the rest — no echo on the track to place.
    static func estimateLag(mic: Track, reference: Track,
                            maxSeconds: Int = 600, maxLagMs: Int = 250) -> Int? {
        let frame = 4096, n = 8192
        guard let fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD),
              let inv = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .INVERSE) else { return nil }
        defer { vDSP_DFT_DestroySetup(fwd); vDSP_DFT_DestroySetup(inv) }

        func buf() -> UnsafeMutablePointer<Float> {
            let p = UnsafeMutablePointer<Float>.allocate(capacity: n)
            p.initialize(repeating: 0, count: n)
            return p
        }
        let mRe = buf(), mIm = buf(), rRe = buf(), rIm = buf()
        let zero = buf(), sRe = buf(), sIm = buf(), tRe = buf(), tIm = buf()
        defer { [mRe, mIm, rRe, rIm, zero, sRe, sIm, tRe, tIm].forEach { $0.deallocate() } }

        let end = min(min(mic.count, reference.count), maxSeconds * sampleRate) - frame
        var used = 0
        var start = 0
        // Far-end speech, not its noise floor: −45 dBFS.
        let active = Float(0.0056 * 0.0056) * Float(frame)
        while start <= end {
            reference.read(start, frame, tRe)
            var energy: Float = 0
            vDSP_svesq(tRe, 1, &energy, vDSP_Length(frame))
            if energy >= active {
                (tRe + frame).update(repeating: 0, count: n - frame)
                vDSP_DFT_Execute(fwd, tRe, zero, rRe, rIm)
                mic.read(start, frame, tRe)
                (tRe + frame).update(repeating: 0, count: n - frame)
                vDSP_DFT_Execute(fwd, tRe, zero, mRe, mIm)
                // S += M · conj(R)
                var r = DSPSplitComplex(realp: rRe, imagp: rIm)
                var m = DSPSplitComplex(realp: mRe, imagp: mIm)
                var s = DSPSplitComplex(realp: sRe, imagp: sIm)
                vDSP_zvcma(&r, 1, &m, 1, &s, 1, &s, 1, vDSP_Length(n))
                used += 1
            }
            start += frame
        }
        guard used >= 8 else { return nil }

        // Phase transform: whiten so the peak is sharp whatever the room and
        // speakers did to the spectrum.
        for i in 0..<n {
            let mag = (sRe[i] * sRe[i] + sIm[i] * sIm[i]).squareRoot() + 1e-12
            sRe[i] /= mag; sIm[i] /= mag
        }
        vDSP_DFT_Execute(inv, sRe, sIm, tRe, tIm)

        let maxLag = maxLagMs * sampleRate / 1000
        var best = 0, bestValue: Float = 0, sumSq: Float = 0
        for k in -maxLag...maxLag {
            // Polarity is not ours to assume: the 10-05 call's echo came back
            // inverted (gain −0.88).
            let v = abs(tRe[k >= 0 ? k : n + k])
            sumSq += v * v
            if v > bestValue { bestValue = v; best = k }
        }
        let rms = (sumSq / Float(2 * maxLag + 1)).squareRoot()
        // A real echo path stands far above the floor (measured 30–100×);
        // uncorrelated tracks peak at ~4–5× by chance over 8 000 lags.
        return rms > 0 && bestValue / rms >= 10 ? best : nil
    }

    /// The adaptive filter and its buffers. Raw pointers, allocated once: the
    /// inner loop runs ~285 000 blocks on a 76-minute call.
    private final class Filter {
        let b: Int, p: Int, n: Int
        let fwd: vDSP_DFT_Setup, inv: vDSP_DFT_Setup
        // P partitions × N bins, real and imaginary.
        let wRe: UnsafeMutablePointer<Float>, wIm: UnsafeMutablePointer<Float>
        let xRe: UnsafeMutablePointer<Float>, xIm: UnsafeMutablePointer<Float>
        var head = 0
        let px: UnsafeMutablePointer<Float>
        let prevX: UnsafeMutablePointer<Float>
        // Scratch, N each.
        let aRe, aIm, cRe, cIm, zero, yRe, yIm: UnsafeMutablePointer<Float>
        // B each.
        let x, d, e: UnsafeMutablePointer<Float>
        private var all: [UnsafeMutablePointer<Float>] = []

        init(blockSize: Int, partitions: Int) {
            b = blockSize; p = partitions; n = 2 * blockSize
            fwd = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .FORWARD)!
            inv = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(n), .INVERSE)!
            func make(_ count: Int, _ value: Float = 0) -> UnsafeMutablePointer<Float> {
                let q = UnsafeMutablePointer<Float>.allocate(capacity: count)
                q.initialize(repeating: value, count: count)
                return q
            }
            wRe = make(p * n); wIm = make(p * n); xRe = make(p * n); xIm = make(p * n)
            px = make(n, 1e-6); prevX = make(b)
            aRe = make(n); aIm = make(n); cRe = make(n); cIm = make(n)
            zero = make(n); yRe = make(n); yIm = make(n)
            x = make(b); d = make(b); e = make(b)
            all = [wRe, wIm, xRe, xIm, px, prevX, aRe, aIm, cRe, cIm, zero, yRe, yIm, x, d, e]
        }

        deinit {
            all.forEach { $0.deallocate() }
            vDSP_DFT_DestroySetup(fwd); vDSP_DFT_DestroySetup(inv)
        }

        /// Forget the stream position (reference history) but keep what was
        /// learned about the room — the hand-off from warm-up to the real pass.
        func restartStream() {
            xRe.update(repeating: 0, count: p * n); xIm.update(repeating: 0, count: p * n)
            prevX.update(repeating: 0, count: b)
            head = 0
        }

        func resetWeights() {
            wRe.update(repeating: 0, count: p * n); wIm.update(repeating: 0, count: p * n)
        }

        struct Pass {
            /// Mic and output energy over the echo blocks.
            var echoIn = 0.0, echoOut = 0.0
            /// Output level of each echo block, dBFS.
            var residualDB: [Float] = []
            var resets = 0
        }

        /// One pass over `length` mic samples.
        func run(mic: Track, reference: Track, micDelay: Int, refDelay: Int,
                 length: Int, emit: ((UnsafePointer<Float>, Int) -> Void)?) -> Pass {
            let total = length + micDelay
            let blocks = (total + b - 1) / b
            var skip = micDelay, remaining = length
            var pass = Pass()
            var worse = 0
            let activeEnergy = EchoCanceller.referenceActiveRMS * EchoCanceller.referenceActiveRMS * Float(b)
            let audibleEnergy = EchoCanceller.micAudibleRMS * EchoCanceller.micAudibleRMS * Float(b)
            let invN = 1 / Float(n)

            for blk in 0..<blocks {
                let s = blk * b
                reference.read(s - refDelay, b, x)
                mic.read(s - micDelay, b, d)

                // Newest reference spectrum: [previous block, this block].
                head = (head + p - 1) % p
                aRe.update(from: prevX, count: b)
                (aRe + b).update(from: x, count: b)
                vDSP_DFT_Execute(fwd, aRe, zero, xRe + head * n, xIm + head * n)
                prevX.update(from: x, count: b)

                // Echo estimate Y = Σ W[k] · X[k].
                yRe.update(repeating: 0, count: n); yIm.update(repeating: 0, count: n)
                var y = DSPSplitComplex(realp: yRe, imagp: yIm)
                for k in 0..<p {
                    let slot = (head + k) % p
                    var w = DSPSplitComplex(realp: wRe + k * n, imagp: wIm + k * n)
                    var xs = DSPSplitComplex(realp: xRe + slot * n, imagp: xIm + slot * n)
                    vDSP_zvma(&w, 1, &xs, 1, &y, 1, &y, 1, vDSP_Length(n))
                }
                vDSP_DFT_Execute(inv, yRe, yIm, aRe, aIm)
                // e = d − y, with y the second half of the inverse transform.
                var scale = invN
                vDSP_vsmul(aRe + b, 1, &scale, cRe, 1, vDSP_Length(b))
                vDSP_vsub(cRe, 1, d, 1, e, 1, vDSP_Length(b))

                var ed: Float = 0, ee: Float = 0, ey: Float = 0, ex: Float = 0
                vDSP_svesq(d, 1, &ed, vDSP_Length(b))
                vDSP_svesq(e, 1, &ee, vDSP_Length(b))
                vDSP_svesq(cRe, 1, &ey, vDSP_Length(b))
                vDSP_svesq(x, 1, &ex, vDSP_Length(b))

                // Never louder than the mic: a block the filter made worse is
                // passed through as recorded.
                let better = ee <= ed
                let out = better ? ee : ed
                if ex >= activeEnergy && ed >= audibleEnergy && ey >= EchoCanceller.echoShare * ed
                    && ey.isFinite {
                    pass.echoIn += Double(ed)
                    pass.echoOut += Double(out)
                    pass.residualDB.append(10 * log10(max(out / Float(b), 1e-12)))
                }
                // Diverged, not merely unhelpful: an estimate that has run
                // away from anything the mic heard. (An output a little louder
                // than the mic is common and harmless — voice processing's AGC
                // moves the echo under the filter — and is already passed
                // through above; resetting on it threw away the room 37 times
                // on the 10-05 call and cost 6 dB.)
                if !ey.isFinite {
                    resetWeights(); pass.resets += 1; worse = 0
                } else if ey > 100 * ed && ey > 10 * ex && ex >= activeEnergy {
                    // Both, because voice processing zeroes the mic outright
                    // while the far end talks — "louder than the mic" alone
                    // is then any estimate at all. Real echo stays within a
                    // few dB of its reference (+4 dB under the 10-05 call's AGC).
                    worse += 1
                    if worse >= EchoCanceller.divergedBlocks {
                        resetWeights(); pass.resets += 1; worse = 0
                    }
                } else {
                    worse = 0
                }

                if let emit {
                    let src = better ? e : d
                    var from = 0, count = b
                    if skip > 0 { let k = min(skip, b); from = k; count -= k; skip -= k }
                    count = min(count, remaining)
                    if count > 0 { emit(src + from, count); remaining -= count }
                }

                // Adapt. The step follows how much of the error is echo:
                // full while only the far end talks, small while the user
                // talks over it.
                guard ex >= 1e-7 else { continue }
                var mu = ey > 0 ? EchoCanceller.muMax * min(1, ey / (ee + 1e-9))
                                : EchoCanceller.muMax * 0.3
                mu = max(mu, 0.02)

                // px = 0.9 px + 0.1 |X_newest|²
                var xn = DSPSplitComplex(realp: xRe + head * n, imagp: xIm + head * n)
                vDSP_zvmags(&xn, 1, cIm, 1, vDSP_Length(n))
                var a: Float = 0.9, c: Float = 0.1
                vDSP_vsmul(px, 1, &a, px, 1, vDSP_Length(n))
                vDSP_vsma(cIm, 1, &c, px, 1, px, 1, vDSP_Length(n))

                // E = DFT([0, e]); G = mu · E / (P · px + ε)
                aRe.update(repeating: 0, count: b)
                (aRe + b).update(from: e, count: b)
                vDSP_DFT_Execute(fwd, aRe, zero, yRe, yIm)
                for i in 0..<n {
                    let g = mu / (Float(p) * px[i] + 1e-6)
                    yRe[i] *= g; yIm[i] *= g
                }
                var gSpec = DSPSplitComplex(realp: yRe, imagp: yIm)

                for k in 0..<p {
                    let slot = (head + k) % p
                    // Gradient conj(X[k]) · G, constrained to B taps so the
                    // circular convolution stays a linear one.
                    var xs = DSPSplitComplex(realp: xRe + slot * n, imagp: xIm + slot * n)
                    var t = DSPSplitComplex(realp: cRe, imagp: cIm)
                    vDSP_zvcmul(&xs, 1, &gSpec, 1, &t, 1, vDSP_Length(n))
                    vDSP_DFT_Execute(inv, cRe, cIm, aRe, aIm)
                    vDSP_vsmul(aRe, 1, &scale, aRe, 1, vDSP_Length(b))
                    (aRe + b).update(repeating: 0, count: b)
                    vDSP_DFT_Execute(fwd, aRe, zero, cRe, cIm)
                    vDSP_vadd(wRe + k * n, 1, cRe, 1, wRe + k * n, 1, vDSP_Length(n))
                    vDSP_vadd(wIm + k * n, 1, cIm, 1, wIm + k * n, 1, vDSP_Length(n))
                }
            }
            return pass
        }
    }
}
