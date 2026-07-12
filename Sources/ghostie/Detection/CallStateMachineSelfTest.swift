import Foundation

/// Regression check for the call detector state machine. Pure logic over a
/// VirtualClock + scripted evidence, so no audio, no models, no Teams running
/// — green everywhere, in line with the rest of `ghostie selftest`
/// (CLAUDE.md selftest policy).
func runDetectorStateMachineSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else  { failed += 1; print("  ✗ \(name)  \(detail())") }
    }

    // Convenience: build an evidence snapshot. The state machine only cares
    // about primarySignal (teamsInputPids non-empty) and corroborators
    // (output / camera / ax) — all other fields are passed through for logs.
    func ev(at t: VirtualTime,
            input: Bool, output: Bool = false,
            camera: Bool = false, ax: Bool = false,
            swap: Bool = false) -> CallEvidence {
        let pids: [pid_t] = input ? [1234] : []
        let outs: [pid_t] = output ? [1234] : []
        let cams: [pid_t] = camera ? [1234] : []
        let m: MeetingWindowMatch = ax
            ? .matched(reason: "title:Meeting", heuristicsVersion: 1)
            : .notMatched
        return CallEvidence(
            timestamp: t, teamsMainPids: pids, teamsInputPids: pids,
            teamsOutputPids: outs, teamsCameraPids: cams,
            meetingWindow: m, defaultInputDeviceId: 42,
            deviceSwapWithinLast3s: swap)
    }

    // Test harness: spin up a fresh machine + clock, return both.
    func newMachine() -> (CallStateMachine, VirtualClock, () -> Int, () -> Int) {
        let clock = VirtualClock()
        let sm = CallStateMachine(clock: clock)
        var starts = 0, stops = 0
        sm.onCallStart = { _ in starts += 1 }
        sm.onCallStop  = { _ in stops  += 1 }
        return (sm, clock, { starts }, { stops })
    }

    // Drive evidence at 0.5s steps so the candidate/end timers fire on a
    // realistic-ish cadence; the state machine itself doesn't poll.
    func drive(_ sm: CallStateMachine, _ clock: VirtualClock,
               for seconds: TimeInterval,
               step: TimeInterval = 0.5,
               evidence: (VirtualTime) -> CallEvidence) {
        let n = max(1, Int((seconds / step).rounded()))
        for _ in 0..<n {
            clock.advance(by: step)
            sm.evaluate(evidence: evidence(clock.now))
        }
    }

    // 1. Cold start with primary + one corroborator (output) promotes after
    //    confirmSeconds (=3).
    do {
        let (sm, clock, starts, _) = newMachine()
        sm.evaluate(evidence: ev(at: clock.now, input: true, output: true))
        check("cold start: enters candidate", sm.stage == .candidate, "got \(sm.stage)")
        drive(sm, clock, for: 3.5) { ev(at: $0, input: true, output: true) }
        check("cold start: promotes to confirmed after >=3s",
              sm.stage == .confirmed && starts() == 1,
              "stage=\(sm.stage) starts=\(starts())")
    }

    // 2. Cold start with primary only (no corroborators) stays in candidate
    //    indefinitely and never commits a call. A corroborator-less primary
    //    costs only a tentative capture (in-memory ring; discarded on
    //    demotion, never announced or processed).
    do {
        let (sm, clock, starts, stops) = newMachine()
        sm.evaluate(evidence: ev(at: clock.now, input: true))
        drive(sm, clock, for: 60) { ev(at: $0, input: true) }
        check("primary-only: stays candidate, never promotes",
              sm.stage == .candidate && starts() == 0,
              "stage=\(sm.stage) starts=\(starts())")
        // Once primary drops for >8s, candidate is abandoned. Tightened to
        // also assert stops()==0: the original assertion only checked starts
        // and missed that demotion used to emit a phantom onCallStop for a
        // session that never announced a start (bug fix pin).
        drive(sm, clock, for: 10) { ev(at: $0, input: false) }
        check("primary-only: demoted to idle after primary loss >8s, silently",
              sm.stage == .idle && starts() == 0 && stops() == 0,
              "stage=\(sm.stage) starts=\(starts()) stops=\(stops())")
    }

    // 2b. Candidate -> idle demotion is silent even when the candidate had a
    //     corroborator: the session never confirmed, so onCallStop must not
    //     fire — consumers expect start/stop as a balanced pair.
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 2) { ev(at: $0, input: true, output: true) }
        check("candidate-demotion: in candidate before primary drop",
              sm.stage == .candidate, "got \(sm.stage)")
        drive(sm, clock, for: 9) { ev(at: $0, input: false) }
        check("candidate-demotion: idle with no start and no stop",
              sm.stage == .idle && starts() == 0 && stops() == 0,
              "stage=\(sm.stage) starts=\(starts()) stops=\(stops())")
    }

    // 3. Listener-only meeting: only output present, no input. Primary stays
    //    false, machine never even enters candidate.
    do {
        let (sm, clock, starts, _) = newMachine()
        drive(sm, clock, for: 10) { ev(at: $0, input: false, output: true) }
        check("output-only: never enters candidate",
              sm.stage == .idle && starts() == 0)
    }

    // 4. Camera alone does NOT corroborate (the approximation is too weak;
    //    see CallEvidence.corroborators). Camera + output DOES.
    do {
        let (sm, clock, starts, _) = newMachine()
        drive(sm, clock, for: 5) { ev(at: $0, input: true, camera: true) }
        check("primary + camera-only stays candidate (camera is tie-breaker)",
              sm.stage == .candidate && starts() == 0,
              "stage=\(sm.stage) starts=\(starts())")

        let (sm2, clock2, starts2, _) = newMachine()
        drive(sm2, clock2, for: 3.5) { ev(at: $0, input: true, output: true, camera: true) }
        check("primary + output + camera promotes",
              sm2.stage == .confirmed && starts2() == 1)
    }

    // 5. AX-only corroboration: mic on, AX matched, promotes.
    do {
        let (sm, clock, starts, _) = newMachine()
        drive(sm, clock, for: 3.5) { ev(at: $0, input: true, ax: true) }
        check("ax-only corroboration promotes",
              sm.stage == .confirmed && starts() == 1)
    }

    // 6. Device hot-swap during candidate: a quiescence pulse lets us
    //    survive a brief primary=false even before promotion.
    do {
        let (sm, clock, starts, _) = newMachine()
        drive(sm, clock, for: 2) { ev(at: $0, input: true, output: true) }
        check("hot-swap@candidate: still candidate at 2s", sm.stage == .candidate)
        // Mid-candidate: device swaps, input briefly drops, but swap quiescence
        // counts as effective primary.
        drive(sm, clock, for: 2) { ev(at: $0, input: false, output: true, swap: true) }
        check("hot-swap@candidate: quiescence holds the candidate",
              sm.stage == .candidate, "got \(sm.stage)")
        // Recovery: input returns, corroborator still present, promotes.
        drive(sm, clock, for: 3.5) { ev(at: $0, input: true, output: true) }
        check("hot-swap@candidate: promotes after recovery",
              sm.stage == .confirmed && starts() == 1)
    }

    // 6b. Device hot-swap whose quiescence expires while ending: once the
    //     3 s swap window passes, primary=false re-asserts, ending continues,
    //     and grace eventually fires.
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true) }
        check("hot-swap-then-real-loss: setup confirmed", sm.stage == .confirmed)
        // Swap pulse (3s of suppression) followed by real primary loss.
        drive(sm, clock, for: 3) { ev(at: $0, input: false, output: true, swap: true) }
        check("hot-swap-then-real-loss: still confirmed during quiescence",
              sm.stage == .confirmed)
        // Pulse expired, primary still gone, output still present (so we
        // enter ending, not idle).
        drive(sm, clock, for: 1) { ev(at: $0, input: false, output: true) }
        check("hot-swap-then-real-loss: enters ending after quiescence",
              sm.stage == .ending)
        drive(sm, clock, for: 31) { ev(at: $0, input: false, output: true) }
        check("hot-swap-then-real-loss: idle after full grace, single stop",
              sm.stage == .idle && starts() == 1 && stops() == 1,
              "stage=\(sm.stage) starts=\(starts()) stops=\(stops())")
    }

    // 7. Device hot-swap during confirmed: input briefly drops, quiescence
    //    suppresses the ending transition.
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true) }
        check("hot-swap@confirmed: setup confirmed", sm.stage == .confirmed)
        drive(sm, clock, for: 2.5) { ev(at: $0, input: false, output: true, swap: true) }
        // Also assert no confirmed->ending edge was even logged: the stage
        // alone could mask an ending bounce-and-recover. Pins the legitimate
        // ride-over so tightening quiescence elsewhere can't overcorrect.
        check("hot-swap@confirmed: quiescence suppresses ending",
              sm.stage == .confirmed
              && !sm.transitions.contains { $0.from == .confirmed && $0.to == .ending },
              "stage=\(sm.stage) edges=\(sm.transitions.map { "\($0.from.rawValue)->\($0.to.rawValue)" })")
        drive(sm, clock, for: 5) { ev(at: $0, input: true, output: true) }
        check("hot-swap@confirmed: still confirmed, no stop emitted",
              sm.stage == .confirmed && starts() == 1 && stops() == 0)
    }

    // 7b. Device swap while idle must NOT create a candidate: quiescence
    //     suppresses primary loss during a call, it never synthesizes primary
    //     presence from idle. (Bug fix pin: unplugging AirPods at the desk
    //     used to create a phantom session — and a phantom "call ended".)
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 5) { ev(at: $0, input: false, swap: true) }
        check("idle-swap: stays idle, no session, no transitions",
              sm.stage == .idle && sm.sessionId == nil
              && starts() == 0 && stops() == 0 && sm.transitions.isEmpty,
              "stage=\(sm.stage) sid=\(String(describing: sm.sessionId)) transitions=\(sm.transitions.count)")
    }

    // 7c. Continuous device flapping (a flaky Bluetooth device cycling
    //     faster than the 3 s swap window) must not pin a dead call open
    //     forever: quiescence alone may sustain effectivePrimary for at most
    //     2x endGraceSeconds (60 s) past the last REAL primary observation,
    //     after which the normal 30 s ending grace runs and the call closes
    //     with a single stop.
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true) }
        check("flap-cap: setup confirmed", sm.stage == .confirmed)
        // Device flaps forever: swap stays asserted, real primary never returns.
        drive(sm, clock, for: 59) { ev(at: $0, input: false, output: true, swap: true) }
        check("flap-cap: still confirmed within the 60s sustain cap",
              sm.stage == .confirmed, "stage=\(sm.stage)")
        drive(sm, clock, for: 2) { ev(at: $0, input: false, output: true, swap: true) }
        check("flap-cap: enters ending once the cap is exceeded",
              sm.stage == .ending, "stage=\(sm.stage)")
        drive(sm, clock, for: 31) { ev(at: $0, input: false, output: true, swap: true) }
        check("flap-cap: idle after grace despite continued flapping, single stop",
              sm.stage == .idle && starts() == 1 && stops() == 1,
              "stage=\(sm.stage) starts=\(starts()) stops=\(stops())")
    }

    // 8. Teams process death with another Teams PID resuming input within
    //    grace: still the same session, no stop fires.
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true) }
        let sessionBefore = sm.sessionId
        // Crash: input + output both gone (process is dead).
        drive(sm, clock, for: 10) { ev(at: $0, input: false) }
        check("crash: enters ending", sm.stage == .ending, "stage=\(sm.stage)")
        // New PID picks up input + output before grace elapses.
        drive(sm, clock, for: 3) { ev(at: $0, input: true, output: true) }
        check("crash: returns to confirmed within grace",
              sm.stage == .confirmed && starts() == 1 && stops() == 0)
        check("crash: same session preserved", sm.sessionId == sessionBefore)
    }

    // 9. Teams process death with no resumption: clean end after grace, stop
    //    fires once.
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true) }
        check("clean-end: setup confirmed", sm.stage == .confirmed)
        drive(sm, clock, for: 31) { _ in
            CallEvidence(timestamp: 0, teamsMainPids: [], teamsInputPids: [],
                         teamsOutputPids: [], teamsCameraPids: [],
                         meetingWindow: .notMatched, defaultInputDeviceId: nil,
                         deviceSwapWithinLast3s: false)
        }
        check("clean-end: idle after grace, single stop",
              sm.stage == .idle && starts() == 1 && stops() == 1,
              "stage=\(sm.stage) starts=\(starts()) stops=\(stops())")
    }

    // 10. Mute via AudioUnit close mid-call: primary still observed (Teams
    //     still holds input I/O; mute is library-level, not session-level), no
    //     stop.
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true) }
        // Hardware/UI mute that DOES close the AudioUnit -> input=false.
        // Meeting window (AX) is still up. Output is still arriving (we hear
        // others). Corroborators alone keep the call alive once primary
        // returns; while primary is false we're in ending, but the corroborator
        // staying present is what makes recovery within grace certain.
        drive(sm, clock, for: 20) { ev(at: $0, input: false, output: true, ax: true) }
        check("mute: in ending while primary false",
              sm.stage == .ending)
        // User unmutes (or AudioUnit returns) before grace elapses.
        drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true, ax: true) }
        check("mute: returns to confirmed, no split",
              sm.stage == .confirmed && starts() == 1 && stops() == 0)
    }

    // 11. Back-to-back meetings, short gap (6s) collapses into one session.
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 5) { ev(at: $0, input: true, output: true) }
        let sessionA = sm.sessionId
        drive(sm, clock, for: 6) { ev(at: $0, input: false) }
        drive(sm, clock, for: 5) { ev(at: $0, input: true, output: true) }
        check("back-to-back 6s gap: same session, no split",
              sm.stage == .confirmed && starts() == 1 && stops() == 0
              && sm.sessionId == sessionA)
    }

    // 12. Back-to-back meetings, long gap (35s) splits into two sessions.
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 5) { ev(at: $0, input: true, output: true) }
        let sessionA = sm.sessionId
        drive(sm, clock, for: 35) { ev(at: $0, input: false) }
        check("back-to-back 35s gap: first call ends",
              sm.stage == .idle && stops() == 1)
        drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true) }
        check("back-to-back 35s gap: second call confirmed (distinct session)",
              sm.stage == .confirmed && starts() == 2 && sm.sessionId != sessionA)
    }

    // 13. AX permission unavailable: still confirmable via output corroborator.
    do {
        let (sm, clock, starts, _) = newMachine()
        let unavailable = MeetingWindowMatch.unavailable(reason: "permission denied")
        drive(sm, clock, for: 3.5) { t in
            CallEvidence(timestamp: t, teamsMainPids: [1234],
                         teamsInputPids: [1234], teamsOutputPids: [1234],
                         teamsCameraPids: [], meetingWindow: unavailable,
                         defaultInputDeviceId: 42, deviceSwapWithinLast3s: false)
        }
        check("ax-unavailable: output corroborator still promotes",
              sm.stage == .confirmed && starts() == 1)
    }

    // 14. AX permission revoked mid-call: machine continues (the corroborator
    //     "disappearing" is fine while primary is still observed).
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true, ax: true) }
        check("ax-revoke: confirmed before revocation", sm.stage == .confirmed)
        let unavailable = MeetingWindowMatch.unavailable(reason: "revoked")
        drive(sm, clock, for: 10) { t in
            CallEvidence(timestamp: t, teamsMainPids: [1234],
                         teamsInputPids: [1234], teamsOutputPids: [1234],
                         teamsCameraPids: [], meetingWindow: unavailable,
                         defaultInputDeviceId: 42, deviceSwapWithinLast3s: false)
        }
        check("ax-revoke: continues, no stop emitted",
              sm.stage == .confirmed && starts() == 1 && stops() == 0)
    }

    // 15. forceStop() emits onCallStop and returns to idle.
    do {
        let (sm, clock, starts, stops) = newMachine()
        drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true) }
        check("forceStop: setup confirmed", sm.stage == .confirmed)
        sm.forceStop(reason: "selftest")
        check("forceStop: idle + stop emitted",
              sm.stage == .idle && starts() == 1 && stops() == 1)
    }

    // 15b. Tentative capture callbacks. onTentativeStart fires on entering
    //      candidate; onTentativeDiscard fires only for a candidate that
    //      demotes without confirming; a confirmed session emits stop, never
    //      discard — the pairs are mutually exclusive.
    do {
        func newTentativeMachine() -> (CallStateMachine, VirtualClock,
                                       () -> Int, () -> Int, () -> Int, () -> Int) {
            let clock = VirtualClock()
            let sm = CallStateMachine(clock: clock)
            var starts = 0, stops = 0, tentStarts = 0, discards = 0
            sm.onCallStart = { _ in starts += 1 }
            sm.onCallStop  = { _ in stops  += 1 }
            sm.onTentativeStart   = { _ in tentStarts += 1 }
            sm.onTentativeDiscard = { _ in discards += 1 }
            return (sm, clock, { starts }, { stops }, { tentStarts }, { discards })
        }

        // Confirmed lifecycle: tentative start on candidate entry, call start
        // on promotion, stop on grace expiry — and no discard anywhere.
        do {
            let (sm, clock, starts, stops, tentStarts, discards) = newTentativeMachine()
            sm.evaluate(evidence: ev(at: clock.now, input: true, output: true))
            check("tentative: fires on idle->candidate",
                  tentStarts() == 1 && starts() == 0,
                  "tentStarts=\(tentStarts()) starts=\(starts())")
            drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true) }
            check("tentative: promotion adopts capture (start fired, no discard)",
                  starts() == 1 && discards() == 0,
                  "starts=\(starts()) discards=\(discards())")
            drive(sm, clock, for: 35) { ev(at: $0, input: false) }
            check("tentative: confirmed session ends with stop, never discard",
                  sm.stage == .idle && stops() == 1 && discards() == 0,
                  "stage=\(sm.stage) stops=\(stops()) discards=\(discards())")
        }

        // Demoted candidate: discard fires exactly once, start/stop never.
        do {
            let (sm, clock, starts, stops, tentStarts, discards) = newTentativeMachine()
            drive(sm, clock, for: 2) { ev(at: $0, input: true) }
            drive(sm, clock, for: 10) { ev(at: $0, input: false) }
            check("tentative: demoted candidate discards exactly once",
                  sm.stage == .idle && tentStarts() == 1 && discards() == 1
                      && starts() == 0 && stops() == 0,
                  "tentStarts=\(tentStarts()) discards=\(discards()) starts=\(starts()) stops=\(stops())")
        }

        // forceStop mid-candidate is also a discard, not a stop.
        do {
            let (sm, clock, starts, stops, _, discards) = newTentativeMachine()
            drive(sm, clock, for: 1.5) { ev(at: $0, input: true, output: true) }
            check("tentative: forceStop setup in candidate", sm.stage == .candidate)
            sm.forceStop(reason: "selftest")
            check("tentative: forceStop mid-candidate discards silently",
                  sm.stage == .idle && discards() == 1 && starts() == 0 && stops() == 0,
                  "discards=\(discards()) starts=\(starts()) stops=\(stops())")
        }
    }

    // 16. Transition log: at least one transition appears for each lifecycle
    //     edge in the confirmed lifecycle. Used by diagnose-detect.
    do {
        let (sm, clock, _, _) = newMachine()
        drive(sm, clock, for: 4) { ev(at: $0, input: true, output: true) }
        drive(sm, clock, for: 35) { ev(at: $0, input: false) }
        let edges = sm.transitions.map { "\($0.from.rawValue)->\($0.to.rawValue)" }
        check("transition log records full lifecycle",
              edges.contains("idle->candidate")
              && edges.contains("candidate->confirmed")
              && edges.contains("confirmed->ending")
              && edges.contains("ending->idle"),
              "got \(edges)")
    }

    // 17. MeetingWindowHeuristics.v1 against fixtures. These are the patterns
    //     we are confident about today; bump to v2 with more fixtures once
    //     real Teams meetings have been captured in `diagnose-detect`.
    do {
        typealias A = MeetingWindowHeuristics.Attributes
        let v1 = MeetingWindowHeuristics.v1
        let fixtures: [(name: String, attrs: A, expect: Bool)] = [
            ("main chat window does not match",
             A(title: "Microsoft Teams", roleDescription: "standard window", subrole: "AXStandardWindow"),
             false),
            ("activity tab does not match",
             A(title: "Activity | Microsoft Teams", roleDescription: "standard window", subrole: "AXStandardWindow"),
             false),
            ("calendar tab does not match",
             A(title: "Calendar | Microsoft Teams", roleDescription: "standard window", subrole: "AXStandardWindow"),
             false),
            ("'Meeting with David | Microsoft Teams' matches",
             A(title: "Meeting with David | Microsoft Teams", roleDescription: "standard window", subrole: "AXStandardWindow"),
             true),
            ("'Call with David | Microsoft Teams' matches",
             A(title: "Call with David | Microsoft Teams", roleDescription: "standard window", subrole: "AXStandardWindow"),
             true),
            ("role-description 'Meeting controls' matches independent of title",
             A(title: "", roleDescription: "Meeting controls", subrole: ""),
             true),
            ("a window literally titled 'Meeting Notes' (no Teams suffix) does not match",
             A(title: "Meeting Notes", roleDescription: "standard window", subrole: "AXStandardWindow"),
             false),
        ]
        for (name, attrs, expect) in fixtures {
            let got = v1.evaluate(attrs) != nil
            check("heuristics v1: \(name)", got == expect,
                  "expected \(expect), got \(got)")
        }
    }

    // 18. diagnose-detect --json emits line-delimited JSON that round-trips
    //     through JSONSerialization. Driven against a real
    //     DetectionCoordinator (no fake providers); short duration so the
    //     selftest stays snappy.
    do {
        var lines: [String] = []
        DiagnoseDetect.run(config: Config.load(),
                           duration: 1.2,
                           jsonMode: true,
                           refreshSeconds: 0.5) { lines.append($0) }
        let parsed = lines.compactMap { line -> [String: Any]? in
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any]
            else { return nil }
            return o
        }
        check("diagnose-detect --json: produced at least one tick",
              !lines.isEmpty, "got \(lines.count) lines")
        check("diagnose-detect --json: all lines parse as JSON objects",
              parsed.count == lines.count,
              "parsed \(parsed.count) of \(lines.count)")
        check("diagnose-detect --json: required keys present",
              parsed.allSatisfy { o in
                  o["stage"] != nil && o["evidence"] != nil
                  && o["ts"] != nil && o["transitions_count"] != nil
              })
    }

    print("\ncall-detector self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
