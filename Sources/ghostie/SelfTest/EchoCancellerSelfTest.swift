import CoreAudio
import Foundation

/// Regression check for the after-the-call echo canceller (`EchoCanceller`)
/// and the output rule that sends the recorder to the raw mic (`OutputRoute`).
///
/// Synthetic, so it needs no audio and no device: two talkers made of shaped
/// noise switching on and off at different rates, and a "room" that plays one
/// into the other's mic through a few reflections. The mic leads its reference
/// by 37 ms, which is what the raw tap measured against the system track on
/// 2026-10-06 — the case a causal-only canceller would miss entirely.
func runEchoCancellerSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)\n      \(detail())") }
    }

    let sr = EchoCanceller.sampleRate
    let seconds = 40
    let count = seconds * sr

    /// Speech-shaped: low-passed noise at ≈ −26 dBFS, gated on and off.
    func talker(seed: UInt32, onMs: Int, offMs: Int, offsetMs: Int) -> [Float] {
        var state = seed, low: Float = 0
        var out = [Float](repeating: 0, count: count)
        let period = (onMs + offMs) * sr / 1000, on = onMs * sr / 1000
        let offset = offsetMs * sr / 1000
        for i in 0..<count {
            state = state &* 1_664_525 &+ 1_013_904_223
            let white = Float(Int32(bitPattern: state)) / Float(Int32.max)
            low = 0.7 * low + 0.3 * white
            out[i] = (i + offset) % period < on ? low * 0.12 : 0
        }
        return out
    }
    /// The far end through the speakers into the mic: a direct path `delay`
    /// samples late (negative: the mic track runs ahead) and three reflections.
    func room(_ x: [Float], delay: Int, gain: Float) -> [Float] {
        let taps: [(Int, Float)] = [(0, 1), (40, 0.5), (130, -0.3), (400, 0.2)]
        var out = [Float](repeating: 0, count: x.count)
        for i in 0..<x.count {
            var v: Float = 0
            for (lag, g) in taps {
                let j = i - delay - lag
                if j >= 0 && j < x.count { v += g * x[j] }
            }
            out[i] = gain * v
        }
        return out
    }
    func energy(_ a: [Float], _ r: Range<Int>) -> Float {
        r.reduce(Float(0)) { $0 + a[$1] * a[$1] }
    }
    func db(_ num: Float, _ den: Float) -> Float { 10 * log10(max(num, 1e-20) / max(den, 1e-20)) }
    func sum(_ a: [Float], _ b: [Float]) -> [Float] { zip(a, b).map { $0 + $1 } }

    let far = talker(seed: 7, onMs: 900, offMs: 400, offsetMs: 0)
    let near = talker(seed: 99, onMs: 700, offMs: 1100, offsetMs: 300)
    let leadMs = -37
    let lead = leadMs * sr / 1000
    let echo = room(far, delay: lead, gain: 0.5)

    // ---- Where the echo is.
    let lag = EchoCanceller.estimateLag(mic: .floats(echo), reference: .floats(far))
    check("finds a mic track running 37 ms ahead of its reference",
          lag.map { abs($0 - lead) <= 16 } ?? false, "estimated \(String(describing: lag)) samples, want \(lead)")
    let late = EchoCanceller.estimateLag(mic: .floats(room(far, delay: 60 * sr / 1000, gain: 0.5)),
                                         reference: .floats(far))
    check("finds a mic track running 60 ms behind",
          late.map { abs($0 - 960) <= 16 } ?? false, "estimated \(String(describing: late))")
    check("no echo path where the tracks are unrelated",
          EchoCanceller.estimateLag(mic: .floats(near), reference: .floats(far)) == nil)

    // ---- Echo alone.
    let (clean, stats) = EchoCanceller.cancel(mic: echo, reference: far)
    check("output is exactly as long as the mic track", clean.count == echo.count,
          "\(clean.count) vs \(echo.count)")
    let body = (2 * sr)..<count
    check("removes at least 20 dB of echo", db(energy(echo, body), energy(clean, body)) >= 20,
          "removed \(db(energy(echo, body), energy(clean, body))) dB")
    let opening = 0..<(2 * sr)
    check("the first two seconds are already cancelled (warm start)",
          db(energy(echo, opening), energy(clean, opening)) >= 15,
          "removed \(db(energy(echo, opening), energy(clean, opening))) dB")
    check("reports the echo it removed, and that it is worth applying",
          stats.worthApplying && stats.reductionDB >= 15, "\(stats)")
    check("reports the echo path it found",
          stats.lagMs.map { abs($0 - Double(leadMs)) <= 1 } ?? false, "\(stats)")

    // ---- The user talking over the far end.
    let mixed = sum(echo, near)
    let (heard, _) = EchoCanceller.cancel(mic: mixed, reference: far)
    let nearOn = body.filter { near[$0] != 0 }
    let residue = nearOn.reduce(Float(0)) { $0 + (heard[$1] - near[$1]) * (heard[$1] - near[$1]) }
    let nearEnergy = nearOn.reduce(Float(0)) { $0 + near[$1] * near[$1] }
    let projected = nearOn.reduce(Float(0)) { $0 + heard[$1] * near[$1] }
    check("the user's voice comes through intact over the far end (±1 dB)",
          abs(db(projected, nearEnergy)) <= 1, "gain \(db(projected, nearEnergy)) dB")
    check("what is left besides the user's voice is ≥ 15 dB below it",
          db(residue, nearEnergy) <= -15, "residue \(db(residue, nearEnergy)) dB")

    // ---- Echo the filter cannot follow: a gain jumping every 125 ms, the
    // way voice processing's AGC rode the 10-05 call. Half-cancelled echo is
    // still words to whisper but too rare for the text guard to engage, so
    // it must be left to the guard, not handed on.
    var agc: UInt32 = 3, gain: Float = 1
    let ridden = echo.enumerated().map { i, v -> Float in
        if i % (sr / 8) == 0 {
            agc = agc &* 1_664_525 &+ 1_013_904_223
            gain = 1.2 + 4.8 * Float(agc >> 8) / Float(1 << 24)
        }
        return v * gain
    }
    let (_, rodeStats) = EchoCanceller.cancel(mic: ridden, reference: far)
    check("echo it cannot make quiet is noticed…", rodeStats.hadEcho, "\(rodeStats)")
    check("…and not applied", !rodeStats.worthApplying, "\(rodeStats)")

    // ---- Nothing to cancel.
    let (untouched, quiet) = EchoCanceller.cancel(mic: near, reference: far)
    check("no echo on the track: says it is not worth applying", !quiet.worthApplying, "\(quiet)")
    let drift = zip(untouched, near).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) }
    check("no echo on the track: the voice is left essentially as recorded",
          db(drift, energy(near, 0..<count)) <= -30, "difference \(db(drift, energy(near, 0..<count))) dB")
    let silence = [Float](repeating: 0, count: count)
    let (asRecorded, none) = EchoCanceller.cancel(mic: near, reference: silence)
    check("a silent far end changes nothing at all", asRecorded == near && none.lagMs == nil)

    // ---- Never louder than the mic.
    var louder = 0
    for (input, output) in [(echo, clean), (mixed, heard), (near, untouched)] {
        for start in stride(from: 0, to: count - 256, by: 256) {
            let r = start..<(start + 256)
            if energy(output, r) > energy(input, r) * 1.0001 + 1e-12 { louder += 1 }
        }
    }
    check("no block comes out louder than the mic recorded it", louder == 0, "\(louder) blocks")

    // ---- Which outputs voice processing can cancel through.
    let ispk: UInt32 = 0x6973_706B
    check("the built-in headphone jack defeats voice processing",
          !OutputRoute.voiceProcessingCancelsEcho(transport: kAudioDeviceTransportTypeBuiltIn,
                                                  dataSource: OutputRoute.headphonePort))
    check("the MacBook's own speakers do not",
          OutputRoute.voiceProcessingCancelsEcho(transport: kAudioDeviceTransportTypeBuiltIn,
                                                 dataSource: ispk))
    check("Bluetooth headphones are left on voice processing",
          OutputRoute.voiceProcessingCancelsEcho(transport: kAudioDeviceTransportTypeBluetooth,
                                                 dataSource: nil))
    check("a USB device is left on voice processing whatever it reports",
          OutputRoute.voiceProcessingCancelsEcho(transport: kAudioDeviceTransportTypeUSB,
                                                 dataSource: OutputRoute.headphonePort))
    check("a built-in output with no data source is left on voice processing",
          OutputRoute.voiceProcessingCancelsEcho(transport: kAudioDeviceTransportTypeBuiltIn,
                                                 dataSource: nil))

    print("EchoCanceller self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
