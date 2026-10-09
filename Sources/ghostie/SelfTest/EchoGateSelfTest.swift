import Foundation

/// Regression check for the level-based echo gate (`EchoGate`) and the span
/// hand-back after the text guard (`Pipeline.keepingSpans`).
///
/// Synthetic envelopes, so no audio or device is needed: a ten-minute call in
/// 50 ms peaks where the far end talks three seconds in every five and comes
/// back into the mic 25 dB down, 50 ms early (the raw tap leads its
/// reference). Against that the user talks into the far end's silence, talks
/// over it, says a one-block "yeah", and the echo throws one lone peak 8 dB
/// over its usual level — the four cases the gate has to tell apart.
func runEchoGateSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)\n      \(detail())") }
    }
    print("EchoGate:")

    let windowMs = 50
    let windows = 12_000                     // 10 minutes
    let cycle = 100                          // 5 s: far end on for 3, off for 2
    let farPeak = 10_000.0                   // ≈ −10 dBFS
    let userPeak = 5_000.0                   // ≈ −16 dBFS
    let noise = 40                           // ≈ −58 dBFS, under the voice threshold
    let leadWindows = 1                      // mic 50 ms ahead of its reference

    var seed: UInt32 = 12_345
    /// ±`db` of deterministic level jitter.
    func jitter(_ db: Double) -> Double {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let u = Double(seed >> 8) / Double(1 << 24) * 2 - 1
        return pow(10, u * db / 20)
    }
    func farOn(_ i: Int) -> Bool { i % cycle < 60 }
    func kind(_ i: Int) -> Int { (i / cycle) % 3 }
    /// The user talking into the far end's silence (cycle kind 0).
    func userAlone(_ i: Int) -> Bool { kind(i) == 0 && (65..<95).contains(i % cycle) }
    /// The user talking over the far end (kind 1).
    func userOver(_ i: Int) -> Bool { kind(i) == 1 && (20..<40).contains(i % cycle) }
    /// One 250 ms block of "yeah" into silence (kind 2).
    func yeah(_ i: Int) -> Bool { kind(i) == 2 && (70..<75).contains(i % cycle) }
    /// One block where the echo alone runs 8 dB hot (kind 2).
    func flicker(_ i: Int) -> Bool { kind(i) == 2 && (30..<35).contains(i % cycle) }

    func call(echoGainDB: (Int) -> Double, farScale: Double = 1)
        -> (me: WavLevel.Envelope, far: WavLevel.Envelope) {
        let far = (0..<windows).map { farOn($0) ? Int(farPeak * farScale * jitter(2)) : 0 }
        let me = (0..<windows).map { i -> Int in
            let j = i + leadWindows
            var level = j < windows ? Double(far[j]) * pow(10, echoGainDB(i) / 20) * jitter(2) : 0
            if flicker(i) { level *= pow(10, 8.0 / 20) }
            if userAlone(i) || userOver(i) || yeah(i) { level = max(level, userPeak * jitter(2)) }
            return max(noise, Int(level))
        }
        return (WavLevel.Envelope(windowMs: windowMs, peaks: me),
                WavLevel.Envelope(windowMs: windowMs, peaks: far))
    }
    let lagMs = -leadWindows * windowMs

    /// Share of blocks satisfying `where` that the profile marks `flag`.
    func share(_ p: EchoGate.Profile, _ flag: KeyPath<EchoGate.Profile, [Bool]>,
               where pick: (Int) -> Bool, from: Int = 0, to: Int = windows) -> Double {
        let k = EchoGate.blockMs / windowMs
        var hit = 0, total = 0
        for b in 0..<p.echo.count {
            let i = b * k
            guard i >= from, i < to, (i..<(i + k)).allSatisfy(pick) else { continue }
            total += 1
            if p[keyPath: flag][b] { hit += 1 }
        }
        return total == 0 ? -1 : Double(hit) / Double(total)
    }
    func pureEcho(_ i: Int) -> Bool {
        farOn(i) && farOn(i + leadWindows) && !userOver(i) && !flicker(i)
    }

    // MARK: Steady room

    let steady = call(echoGainDB: { _ in -25 })
    guard let p = EchoGate.profile(me: steady.me, reference: steady.far, lagMs: lagMs) else {
        check("profile builds over a call with a loud far end", false, "got nil")
        print("  \(passed) passed, \(failed) failed")
        return false
    }
    check("calibrates the echo gain from the call itself",
          abs(p.echoGainDB - -25) < 3, "gain \(p.echoGainDB) dB, expected ≈ −25")

    let echoShare = share(p, \.echo, where: pureEcho)
    check("far end alone in the mic reads as echo (≥ 95% of its blocks)",
          echoShare >= 0.95, "echo share \(echoShare)")
    check("the user talking into silence is never echo",
          share(p, \.own, where: userAlone) == 1, "own share \(share(p, \.own, where: userAlone))")
    check("the user talking over the far end reads as the user",
          share(p, \.own, where: userOver) >= 0.95, "own share \(share(p, \.own, where: userOver))")
    check("a one-block \"yeah\" into silence is kept",
          share(p, \.own, where: yeah) == 1, "own share \(share(p, \.own, where: yeah))")
    check("a lone echo peak 8 dB hot is still echo",
          share(p, \.echo, where: flicker) == 1, "echo share \(share(p, \.echo, where: flicker))")

    // Masking: echo-only stretches leave the decode, the user stays.
    let masked = EchoGate.masking(steady.me, with: p)
    let pureIdx = (0..<windows).filter { pureEcho($0) && pureEcho($0 - 5) && pureEcho($0 + 5) }
    let zeroed = pureIdx.filter { masked.peaks[$0] == 0 }.count
    check("masking zeroes the echo-only stretches",
          Double(zeroed) / Double(pureIdx.count) >= 0.95, "\(zeroed)/\(pureIdx.count) zeroed")
    let userIdx = (0..<windows).filter { userAlone($0) || userOver($0) || yeah($0) }
    check("masking leaves every window of the user's speech as it was",
          userIdx.allSatisfy { masked.peaks[$0] == steady.me.peaks[$0] })

    // Segments, in ms. Cycle 3 is kind 0: its first 3 s are the far end alone.
    let c3 = 3 * cycle * windowMs, c4 = 4 * cycle * windowMs
    check("a segment over the far end's echo alone is dropped",
          EchoGate.isEcho(startMs: c3, endMs: c3 + 2_900, in: p))
    check("a segment over the user talking into silence is kept",
          !EchoGate.isEcho(startMs: c3 + 3_250, endMs: c3 + 4_750, in: p))
    check("a segment over the user talking over the far end is kept",
          !EchoGate.isEcho(startMs: c4 + 1_000, endMs: c4 + 2_000, in: p))
    check("a segment half echo, half the user is kept",
          !EchoGate.isEcho(startMs: c3 + 1_500, endMs: c3 + 4_500, in: p))
    check("a segment without an end is never judged",
          !EchoGate.isEcho(startMs: c3, endMs: nil, in: p))

    // A segment holding the user's speech either side of a long echo-only
    // stretch the masked decode spliced out: judged on everything, the gap
    // outvotes the user; judged on what the decode heard, it is the user.
    do {
        let blocks = 40
        let ownIdx = Set(0..<4).union(36..<40)
        let g = EchoGate.Profile(blockMs: EchoGate.blockMs,
                                 echo: (0..<blocks).map { !ownIdx.contains($0) },
                                 own: (0..<blocks).map { ownIdx.contains($0) },
                                 heard: [Bool](repeating: true, count: blocks),
                                 echoGainDB: -25)
        let k = EchoGate.blockMs / windowMs
        let maskedVoice = WavLevel.Envelope(windowMs: windowMs,
            peaks: (0..<(blocks * k)).map { ownIdx.contains($0 / k) ? 5_000 : 0 })
        let heardOnly = EchoGate.hearing(g, masked: maskedVoice)
        check("hearing: the masked decode hears the user's blocks and not the gap",
              ownIdx.allSatisfy { heardOnly.decoded?[$0] == true }
              && (8..<32).allSatisfy { heardOnly.decoded?[$0] == false })
        check("a segment spanning a spliced-out gap is judged on what was decoded",
              EchoGate.isEcho(startMs: 0, endMs: blocks * EchoGate.blockMs, in: g)
              && !EchoGate.isEcho(startMs: 0, endMs: blocks * EchoGate.blockMs, in: heardOnly))
    }

    // MARK: Speakers turned up halfway through

    let louder = call(echoGainDB: { $0 < windows / 2 ? -25 : -15 })
    if let q = EchoGate.profile(me: louder.me, reference: louder.far, lagMs: lagMs) {
        let late = share(q, \.echo, where: pureEcho, from: windows / 2 + 2_400)
        check("follows a 10 dB volume change mid-call (echo still ≥ 90% echo after it)",
              late >= 0.9, "echo share after the change \(late)")
        let userLate = share(q, \.own, where: userOver, from: windows / 2 + 2_400)
        check("…and the user over the far end still reads as the user",
              userLate >= 0.9, "own share \(userLate)")
    } else {
        check("profile builds across a volume change", false, "got nil")
    }

    // MARK: When it must stand down

    let quiet = call(echoGainDB: { _ in -25 }, farScale: 0.025)   // far end ≈ −42 dBFS
    check("too little loud far end to calibrate on: no profile",
          EchoGate.profile(me: quiet.me, reference: quiet.far, lagMs: lagMs) == nil)

    let short = WavLevel.Envelope(windowMs: windowMs, peaks: Array(steady.me.peaks.prefix(40)))
    let shortFar = WavLevel.Envelope(windowMs: windowMs, peaks: Array(steady.far.peaks.prefix(40)))
    check("two seconds of call: no profile",
          EchoGate.profile(me: short, reference: shortFar, lagMs: lagMs) == nil)

    // A far end whose echo would sit under the decode's voice threshold
    // cannot have put words on the Me track, so nothing there is echo.
    var faint = steady.far.peaks
    for i in 0..<1_200 where farOn(i) { faint[i] = 900 }        // ≈ −31 dBFS → echo ≈ −56
    var meFaint = steady.me.peaks
    for i in 0..<1_200 { meFaint[i] = farOn(i) ? 3_000 : noise }
    if let r = EchoGate.profile(me: WavLevel.Envelope(windowMs: windowMs, peaks: meFaint),
                                reference: WavLevel.Envelope(windowMs: windowMs, peaks: faint),
                                lagMs: lagMs) {
        let k = EchoGate.blockMs / windowMs
        let faintBlocks = (0..<(1_200 / k)).filter { farOn($0 * k) && farOn($0 * k + k - 1) }
        check("a far end too faint to echo audibly never makes the mic echo",
              faintBlocks.allSatisfy { !r.echo[$0] && r.own[$0] })
    } else {
        check("profile builds with a faint opening", false, "got nil")
    }

    // MARK: Spans back after the text guard

    let original = [Transcriber.Segment(startMs: 0, text: "one two three", endMs: 900),
                    Transcriber.Segment(startMs: 1_000, text: "echo echo echo", endMs: 1_800),
                    Transcriber.Segment(startMs: 2_000, text: "four five six", endMs: 2_700)]
    let kept = Pipeline.keepingSpans([(startMs: 0, text: "one two three"),
                                      (startMs: 2_000, text: "four five")], from: original)
    check("the text guard's survivors get whisper's spans back",
          kept.map(\.endMs) == [900, 2_700] && kept.map(\.text) == ["one two three", "four five"],
          "\(kept.map { ($0.startMs, $0.endMs ?? -1, $0.text) })")

    print("  \(passed) passed, \(failed) failed")
    return failed == 0
}
