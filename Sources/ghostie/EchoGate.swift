import Foundation

/// Keeps the far end's echo out of the "Me" transcript by *level*, on the
/// calls where `EchoCanceller` found speaker echo and could not remove it.
///
/// The canceller is linear, and some rooms are not. On the 2026-10-09 Meet
/// call (raw RØDE on the desk, speakers on the headphone jack) it took 0.8 dB
/// off 34 minutes of echo: the two tracks correlate at only ~0.6, the echo
/// arrives twice 26 ms apart with opposite polarity, and the lag drifts
/// 0.26 ms a minute. Trained and scored on one five-minute slice it still
/// managed 4.4 dB at best; a full step made it worse and a 512 ms filter
/// diverged. The echo sat at −42 dBFS — above the decode's voice threshold,
/// so whisper wrote it down, and garbled enough ("tell Opus to design this in
/// CAD" came back as "hell opens to design this change cat") that
/// `EchoSuppressor`'s five-identical-words rule let 94 of the user's 386
/// turns through carrying the other person's words.
///
/// What a non-linear room cannot change is *how loud* the echo is. Whatever
/// the speakers and the room do to it, the far end comes back into the mic a
/// roughly fixed number of decibels down — on that call 25 dB at the 250 ms
/// block peaks used here, with 90% of echo blocks within 6 dB of it — while
/// the user, a forearm from the mic, peaks around −16 dBFS against the echo's
/// −35. So: predict each block's echo from the aligned far-end block and the
/// echo gain calibrated on this call, and any mic block no louder than that
/// prediction plus `marginDB` is explained by the far end alone.
///
/// Two uses, both in `Pipeline`:
///   • `masking` zeroes those blocks out of the envelope the code-switch
///     decode splices speech by (`AudioStitcher.spans`), so whisper never
///     hears the echo-only stretches. The recording is not touched.
///   • `isEcho` drops a decoded Me segment whose span the user barely
///     occupies — the backstop for what the decode still heard.
///
/// It only runs on a call the canceller judged to *have* echo it could not
/// remove (`EchoCanceller.Stats.hadEcho && !worthApplying`). A call through
/// headphones, or one voice processing cancelled live, has no echo path and
/// never reaches it. Where the far end is silent nothing is ever judged echo,
/// so the user talking into a quiet line is untouchable whatever the margin.
///
/// The cost, stated plainly: the user speaking *quietly over* the far end —
/// within 6 dB of the echo — reads as echo. At that level whisper could not
/// pull their words out of the far end's anyway.
///
/// Pure over `WavLevel.Envelope`s; covered by `selftest`.
enum EchoGate {

    /// The unit of judgement. 50 ms peaks put the echo's spread at 3.5 dB
    /// between median and upper quartile and 8 dB to the 90th percentile;
    /// 250 ms blocks bring that to 2.8 and 6 (2026-10-09 call), and a word
    /// still spans two of them.
    static let blockMs = 250
    /// Far-end slack either side of the aligned block: the lag drifts
    /// (−54 → −78 ms over the 10-09 call) and the room rings on after the
    /// direct path.
    static let slackMs = 100
    /// A far-end block at least this loud (peak ≈ −30 dBFS) calibrates the
    /// echo gain: loud enough that its echo clears the mic's noise floor.
    static let calibrationPeak = 1_037
    /// How far above the predicted echo a mic block must peak to count as the
    /// user. 6 dB puts 90% of echo blocks under it on the 10-09 call.
    static let marginDB = 6.0
    /// The echo gain is re-measured over this much call either side of each
    /// block, so turning the speakers up halfway through is followed.
    static let calibrationRadiusMs = 120_000
    /// Loud far-end blocks needed before a calibration is trusted: 30 s.
    static let minCalibrationBlocks = 120
    /// While the far end is audible, the user's speech has to hold for this
    /// many consecutive blocks (500 ms) to count — a lone block over the
    /// margin inside a stretch of echo is the echo's own peaks — unless it
    /// clears the prediction by `strongMarginDB`.
    static let minOwnBlocks = 2
    static let strongMarginDB = 15.0
    /// A decoded Me segment is echo when at most this share of its audible
    /// blocks is the user, and at least `minEchoBlocks` of it is echo.
    static let maxOwnShare = 0.2
    static let minEchoBlocks = 2

    struct Profile {
        let blockMs: Int
        /// The far end's echo explains everything the mic heard in this block
        /// (and the far end was loud enough to be heard).
        let echo: [Bool]
        /// The mic heard the user in this block.
        let own: [Bool]
        /// The mic heard anything worth decoding in this block.
        let heard: [Bool]
        /// Echo level relative to the far end, dB (negative): the median over
        /// the whole call. Each block is judged against its own local value.
        let echoGainDB: Double
        /// The blocks the speech-bounded decode heard, when `masking` was
        /// applied to it (`hearing(_:masked:)`); nil when it heard them all.
        var decoded: [Bool]? = nil

        /// Seconds of the call the mic heard only echo.
        var echoSeconds: Double {
            Double(zip(echo, heard).filter { $0 && $1 }.count * blockMs) / 1000
        }
        /// Seconds of the call the mic heard the user.
        var ownSeconds: Double { Double(own.filter { $0 }.count * blockMs) / 1000 }
    }

    // MARK: - Building the profile

    /// Judges every block of the Me track against the far end. `lagMs` is the
    /// canceller's echo path: how far the mic lags the reference (negative:
    /// it leads). nil when there is not enough loud far end to calibrate on —
    /// the caller then leaves the transcript to `EchoSuppressor` alone.
    static func profile(me: WavLevel.Envelope, reference: WavLevel.Envelope,
                        lagMs: Int) -> Profile? {
        let w = me.windowMs
        guard w > 0, reference.windowMs == w, blockMs % w == 0,
              !me.peaks.isEmpty, !reference.peaks.isEmpty else { return nil }
        let k = blockMs / w
        let blocks = (me.peaks.count + k - 1) / k

        var mic = [Int](repeating: 0, count: blocks)
        var far = [Int](repeating: 0, count: blocks)
        for b in 0..<blocks {
            let lo = b * k, hi = min(me.peaks.count, lo + k)
            mic[b] = me.peaks[lo..<hi].max() ?? 0
            // Echo heard at mic time t left the speakers at t − lag.
            let from = b * blockMs - lagMs - slackMs
            let to = (b + 1) * blockMs - lagMs + slackMs
            far[b] = reference.peak(fromMs: from, toMs: to)
        }

        guard let gains = calibrate(mic: mic, far: far) else { return nil }

        let voiceDB = db(AudioStitcher.voiceThreshold)
        var audibleEcho = [Bool](repeating: false, count: blocks)
        var excess = [Double](repeating: -.infinity, count: blocks)
        var heard = [Bool](repeating: false, count: blocks)
        for b in 0..<blocks {
            heard[b] = mic[b] >= AudioStitcher.voiceThreshold
            guard far[b] > 0 else { continue }
            let predicted = db(far[b]) + gains.local[b]
            // A far end too quiet for its echo to reach the decode cannot
            // have put words on the Me track.
            audibleEcho[b] = predicted >= voiceDB
            excess[b] = db(mic[b]) - predicted
        }

        // The user: anything audible while the far end is not echoing, or a
        // sustained (or unmistakable) rise over the predicted echo while it is.
        var rawOwn = [Bool](repeating: false, count: blocks)
        for b in 0..<blocks where heard[b] {
            rawOwn[b] = !audibleEcho[b] || excess[b] > marginDB
        }
        var own = [Bool](repeating: false, count: blocks)
        var b = 0
        while b < blocks {
            guard rawOwn[b] else { b += 1; continue }
            var e = b
            while e + 1 < blocks && rawOwn[e + 1] { e += 1 }
            let sustained = e - b + 1 >= minOwnBlocks
            for i in b...e {
                own[i] = !audibleEcho[i] || sustained || excess[i] > strongMarginDB
            }
            b = e + 1
        }
        let echo = (0..<blocks).map { audibleEcho[$0] && !own[$0] }
        return Profile(blockMs: blockMs, echo: echo, own: own, heard: heard,
                       echoGainDB: gains.median)
    }

    /// The echo gain — mic peak over far-end peak, dB — measured where the far
    /// end was loud: per minute over `calibrationRadiusMs` either side, falling
    /// back to the whole call's median where a stretch has too little far end.
    ///
    /// The median, not a low percentile: while the far end is loud the user is
    /// mostly listening, so most of those blocks are echo alone, and the
    /// user's own speech over it can only pull the median *up* — toward
    /// calling less echo, the safe direction.
    private static func calibrate(mic: [Int], far: [Int])
        -> (median: Double, local: [Double])? {
        let perChunk = max(1, 60_000 / blockMs)
        let chunks = (mic.count + perChunk - 1) / perChunk
        var byChunk = [[Double]](repeating: [], count: chunks)
        var all: [Double] = []
        for b in mic.indices where far[b] >= calibrationPeak && mic[b] > 0 {
            let r = db(mic[b]) - db(far[b])
            byChunk[b / perChunk].append(r)
            all.append(r)
        }
        guard all.count >= minCalibrationBlocks else { return nil }
        let global = median(all)

        let radius = max(0, calibrationRadiusMs / 60_000)
        var chunkGain = [Double](repeating: global, count: chunks)
        for c in 0..<chunks {
            let pooled = (max(0, c - radius)...min(chunks - 1, c + radius))
                .flatMap { byChunk[$0] }
            if pooled.count >= minCalibrationBlocks { chunkGain[c] = median(pooled) }
        }
        return (global, mic.indices.map { chunkGain[$0 / perChunk] })
    }

    // MARK: - Using it

    /// Whether the user barely occupies `[startMs, endMs)` while the far end's
    /// echo fills it. A segment without an end, or outside the profile, is
    /// never judged.
    ///
    /// Only blocks the decode heard are counted (`Profile.decoded`): a
    /// stretch spliced out before decoding cannot have put a word in the
    /// segment, and counting it would hold a removed gap against the user's
    /// sentence either side of it.
    static func isEcho(startMs: Int, endMs: Int?, in p: Profile) -> Bool {
        guard let endMs, endMs > startMs, startMs >= 0 else { return false }
        let first = startMs / p.blockMs
        let last = min(p.echo.count - 1, (endMs - 1) / p.blockMs)
        guard first <= last else { return false }
        var own = 0, echo = 0
        for b in first...last where p.decoded.map({ b < $0.count && $0[b] }) ?? true {
            if p.own[b] { own += 1 } else if p.echo[b] && p.heard[b] { echo += 1 }
        }
        guard echo >= minEchoBlocks else { return false }
        return Double(own) / Double(own + echo) <= maxOwnShare
    }

    /// `voice` with every echo-only block zeroed, so the speech-bounded
    /// decode (`AudioStitcher.spans`) never splices those stretches in. Only
    /// the envelope changes; the audio whisper is handed is untouched.
    static func masking(_ voice: WavLevel.Envelope, with p: Profile) -> WavLevel.Envelope {
        guard voice.windowMs > 0, p.blockMs % voice.windowMs == 0 else { return voice }
        let k = p.blockMs / voice.windowMs
        var peaks = voice.peaks
        for i in peaks.indices {
            let b = i / k
            if b < p.echo.count && p.echo[b] { peaks[i] = 0 }
        }
        return WavLevel.Envelope(windowMs: voice.windowMs, peaks: peaks)
    }

    /// `p`, told which blocks a speech-bounded decode over `masked` (what
    /// `masking` returned) will hear: the spans `AudioStitcher.spans` cuts
    /// from it over the whole track.
    static func hearing(_ p: Profile, masked: WavLevel.Envelope) -> Profile {
        let whole = LanguageRun(language: "", startMs: 0,
                                endMs: masked.peaks.count * masked.windowMs, segments: [])
        var decoded = [Bool](repeating: false, count: p.echo.count)
        for span in AudioStitcher.spans(for: whole, voice: masked) {
            let first = max(0, span.startMs / p.blockMs)
            let last = min(decoded.count - 1, (span.endMs - 1) / p.blockMs)
            if first <= last { for b in first...last { decoded[b] = true } }
        }
        var out = p
        out.decoded = decoded
        return out
    }

    // MARK: - Helpers

    static func db(_ peak: Int) -> Double { 20 * log10(Double(max(peak, 1)) / 32_768) }

    private static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }
}
