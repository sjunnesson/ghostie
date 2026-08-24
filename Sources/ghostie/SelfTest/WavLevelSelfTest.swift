import Foundation

/// Regression check for the silent-track guard.
///
/// The shapes here are the real ones: `me.wav` from the 2026-08-24 call was
/// 59.2 minutes of exact zeros next to a `participants.wav` averaging −34 dBFS,
/// and nothing in the pipeline noticed. The tests below pin both halves of the
/// contract — that a digitally silent track beside a talking one is reported,
/// and that ordinary quiet (a listener, a muted guest, a calm room) is not.
func runWavLevelSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "\n      \(detail)")") }
    }

    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("ghostie-wavlevel-selftest-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    /// Writes `seconds` of 16 kHz mono audio through the real `WavWriter`, so
    /// the probe is exercised against the exact byte layout it meets in
    /// production rather than a hand-rolled header.
    func write(_ name: String, seconds: Double,
               sample: (Int) -> Int16) -> URL? {
        let url = dir.appendingPathComponent(name)
        guard let w = WavWriter(url: url) else { return nil }
        let total = Int(seconds * 16_000)
        var i = 0
        while i < total {
            let n = min(16_000, total - i)
            w.append((0..<n).map { sample(i + $0) })
            i += n
        }
        w.close()
        return url
    }

    // Speech-like: loud enough, and present most of the time.
    func speech(_ i: Int) -> Int16 {
        let t = Double(i) / 16_000
        // 0.9 s of tone per 1.0 s — a talker with short gaps.
        guard t.truncatingRemainder(dividingBy: 1.0) < 0.9 else { return 0 }
        return Int16(8_000 * sin(2 * .pi * 220 * t))
    }
    // A live but idle mic: a noise floor well under the active threshold.
    func noiseFloor(_ i: Int) -> Int16 { Int16(i % 7) - 3 }

    guard let silent = write("silent.wav", seconds: 60, sample: { _ in 0 }),
          let talking = write("talking.wav", seconds: 60, sample: speech),
          let quiet = write("quiet.wav", seconds: 60, sample: noiseFloor) else {
        print("  ✗ could not write fixtures"); return false
    }

    // ---- Probe basics
    let sSilent = WavLevel.probe(silent)
    let sTalk = WavLevel.probe(talking)
    let sQuiet = WavLevel.probe(quiet)
    check("probe reads a WavWriter file", sSilent != nil && sTalk != nil)
    check("duration is recovered", abs((sTalk?.seconds ?? 0) - 60) < 0.1,
          "got \(sTalk?.seconds ?? -1)s")
    check("all-zero track reports digital silence", sSilent?.isDigitalSilence == true)
    check("speech track is not digital silence", sTalk?.isDigitalSilence == false)
    // The fixture is tone for 0.9 s of every 1.0 s, so with 100 ms windows
    // exactly 9 in 10 carry signal — the bound is the fixture's, not a margin.
    check("speech track is mostly active", (sTalk?.activeFraction ?? 0) >= 0.9,
          "active \(sTalk?.activeFraction ?? -1)")
    check("noise floor is not digital silence", sQuiet?.isDigitalSilence == false)
    check("noise floor reads as inactive", (sQuiet?.activeFraction ?? 1) < 0.005,
          "active \(sQuiet?.activeFraction ?? -1)")

    // ---- The verdict the note is written from
    check("silent Me beside talking Participants is reported",
          (Pipeline.trackHealthWarning(mic: silent, sys: talking) ?? "")
            .contains("microphone recorded nothing"))
    check("silent Participants beside talking Me is reported",
          (Pipeline.trackHealthWarning(mic: talking, sys: silent) ?? "")
            .contains("participants' audio was not captured"))
    check("two talking tracks are not reported",
          Pipeline.trackHealthWarning(mic: talking, sys: talking) == nil)
    // The false-positive that would make the warning worthless: a listener who
    // said nothing all call still has a *working* mic, and this is exactly the
    // shape the 2026-08-24 call had on the local side — hence a separate case.
    check("a muted/idle mic beside a talker IS reported",
          Pipeline.trackHealthWarning(mic: quiet, sys: talking) != nil)
    check("a quiet call at both ends is not reported",
          Pipeline.trackHealthWarning(mic: quiet, sys: quiet) == nil)
    check("missing files are not reported",
          Pipeline.trackHealthWarning(
            mic: dir.appendingPathComponent("nope.wav"), sys: talking) == nil)
    check("nil inputs are not reported",
          Pipeline.trackHealthWarning(mic: nil, sys: nil) == nil)

    print("WavLevel self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
