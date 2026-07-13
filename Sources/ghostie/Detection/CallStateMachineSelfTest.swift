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
    // about primarySignal (triggerInputPids non-empty) and corroborators
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
            timestamp: t, triggerMainPids: pids, triggerInputPids: pids,
            triggerOutputPids: outs, triggerCameraPids: cams,
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
            CallEvidence(timestamp: 0, triggerMainPids: [], triggerInputPids: [],
                         triggerOutputPids: [], triggerCameraPids: [],
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
            CallEvidence(timestamp: t, triggerMainPids: [1234],
                         triggerInputPids: [1234], triggerOutputPids: [1234],
                         triggerCameraPids: [], meetingWindow: unavailable,
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
            CallEvidence(timestamp: t, triggerMainPids: [1234],
                         triggerInputPids: [1234], triggerOutputPids: [1234],
                         triggerCameraPids: [], meetingWindow: unavailable,
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

        // Per-app rule selection + the Zoom set. Zoom titles must match only
        // under the Zoom rules, and the selector must route by bundle id.
        let zoom = MeetingWindowHeuristics.zoomV1
        let zoomFixtures: [(name: String, attrs: A, expect: Bool)] = [
            ("in-meeting window matches",
             A(title: "Zoom Meeting", roleDescription: "standard window", subrole: "AXStandardWindow"),
             true),
            ("webinar window matches",
             A(title: "Zoom Webinar", roleDescription: "standard window", subrole: "AXStandardWindow"),
             true),
            ("main Zoom home window does not match",
             A(title: "Zoom Workplace", roleDescription: "standard window", subrole: "AXStandardWindow"),
             false),
            ("settings window does not match",
             A(title: "Settings", roleDescription: "standard window", subrole: "AXStandardWindow"),
             false),
        ]
        for (name, attrs, expect) in zoomFixtures {
            let got = zoom.evaluate(attrs) != nil
            check("heuristics zoomV1: \(name)", got == expect,
                  "expected \(expect), got \(got)")
        }
        check("heuristics: Teams rules ignore Zoom's meeting title",
              v1.evaluate(A(title: "Zoom Meeting", roleDescription: "standard window",
                            subrole: "AXStandardWindow")) == nil)
        check("heuristics selector: zoom bundle → zoom rules, teams bundle → teams rules",
              MeetingWindowHeuristics.forBundleId("us.zoom.xos").rules.count == zoom.rules.count
              && MeetingWindowHeuristics.forBundleId("com.microsoft.teams2").rules.count == v1.rules.count)
    }

    // 17b. Pure coordinator transforms: bundle matcher, evidence builder,
    //      meeting-window resolution — no providers needed.
    do {
        let m = ["com.microsoft.teams", "com.microsoft.teams2"]
        check("matcher: exact id matches",
              DetectionCoordinator.matchesTriggerBundle("com.microsoft.teams", matchers: m))
        check("matcher: classic prefix does not swallow new Teams",
              DetectionCoordinator.matchesTriggerBundle("com.microsoft.teams2", matchers: ["com.microsoft.teams2"])
              && !DetectionCoordinator.matchesTriggerBundle("com.microsoft.teams2", matchers: ["com.microsoft.teams"]))
        check("matcher: helper matches via dot-prefix",
              DetectionCoordinator.matchesTriggerBundle("com.microsoft.teams2.helper.plugin", matchers: m))
        check("matcher: unrelated bundle rejected",
              !DetectionCoordinator.matchesTriggerBundle("com.apple.safari", matchers: m))
        check("matcher: case-insensitive",
              DetectionCoordinator.matchesTriggerBundle("Com.Microsoft.Teams2.Helper", matchers: m))

        let procs = [
            AudioProcessInfo(pid: 10, bundleId: "com.microsoft.teams2", isRunningInput: true, isRunningOutput: false),
            AudioProcessInfo(pid: 11, bundleId: "com.microsoft.teams2.helper", isRunningInput: false, isRunningOutput: true),
            AudioProcessInfo(pid: 99, bundleId: "us.zoom.xos", isRunningInput: true, isRunningOutput: true),
            AudioProcessInfo(pid: 12, bundleId: nil, isRunningInput: true, isRunningOutput: true),
        ]
        let e = DetectionCoordinator.buildEvidence(
            audio: procs, now: 0, matchers: m, defaultDeviceId: 42,
            meetingWindow: .notMatched, cameraPids: [], deviceSwapWithinLast3s: false)
        check("buildEvidence: input/output PIDs filtered to Teams and sorted",
              e.triggerInputPids == [10] && e.triggerOutputPids == [11]
              && e.triggerMainPids == [10, 11],
              "in=\(e.triggerInputPids) out=\(e.triggerOutputPids) all=\(e.triggerMainPids)")

        func isUnavailable(_ m: MeetingWindowMatch) -> Bool {
            if case .unavailable = m { return true } else { return false }
        }
        let ax = FakeDetectionWorld.AX()
        ax.granted = false
        check("resolveMeetingWindow: no PIDs + denied → unavailable",
              isUnavailable(DetectionCoordinator.resolveMeetingWindow(ax: ax, apps: [])))
        ax.granted = true
        check("resolveMeetingWindow: no PIDs + granted → notMatched",
              DetectionCoordinator.resolveMeetingWindow(ax: ax, apps: []) == .notMatched)
        ax.perPid = [1: .unavailable(reason: "launching"), 2: .notMatched]
        check("resolveMeetingWindow: one clean read beats a transient unavailable",
              DetectionCoordinator.resolveMeetingWindow(ax: ax, apps: [RunningAppInfo(pid: 1, bundleId: "com.microsoft.teams2"), RunningAppInfo(pid: 2, bundleId: "com.microsoft.teams2")]) == .notMatched)
        ax.perPid = [1: .unavailable(reason: "launching"),
                     2: .matched(reason: "title", heuristicsVersion: 1)]
        check("resolveMeetingWindow: matched wins",
              DetectionCoordinator.resolveMeetingWindow(ax: ax, apps: [RunningAppInfo(pid: 1, bundleId: "com.microsoft.teams2"), RunningAppInfo(pid: 2, bundleId: "com.microsoft.teams2")]).isMatched)
        ax.perPid = [1: .unavailable(reason: "a"), 2: .unavailable(reason: "b")]
        check("resolveMeetingWindow: all unavailable propagates unavailable",
              isUnavailable(DetectionCoordinator.resolveMeetingWindow(ax: ax, apps: [RunningAppInfo(pid: 1, bundleId: "com.microsoft.teams2"), RunningAppInfo(pid: 2, bundleId: "com.microsoft.teams2")])))
    }

    // 17c. Full lifecycle through a REAL coordinator wired to
    //      FakeDetectionWorld — the scripted-fake harness the rearchitecture
    //      design promised. The VirtualClock scrubs the confirm/grace
    //      windows; only the coordinator's real 300 ms notification debounce
    //      needs short wall-clock waits.
    do {
        final class Counters: @unchecked Sendable {
            private let lock = NSLock()
            private var counts: [String: Int] = [:]
            func bump(_ k: String) { lock.withLock { counts[k, default: 0] += 1 } }
            func get(_ k: String) -> Int { lock.withLock { counts[k] ?? 0 } }
        }
        let world = FakeDetectionWorld()
        let coord = world.makeCoordinator()
        let c = Counters()
        coord.onTentativeStart = { _ in c.bump("tent") }
        coord.onTentativeDiscard = { _ in c.bump("discard") }
        coord.onCallStart = { _ in c.bump("start") }
        coord.onCallStop = { _ in c.bump("stop") }

        func teamsAudio(input: Bool, output: Bool) -> [AudioProcessInfo] {
            [AudioProcessInfo(pid: 100, bundleId: "com.microsoft.teams2",
                              isRunningInput: input, isRunningOutput: output)]
        }
        // Push a change and wait out the 300 ms trailing debounce.
        func settle() { world.audio.notify(); Thread.sleep(forTimeInterval: 0.45) }

        world.presence.apps = [RunningAppInfo(pid: 100, bundleId: "com.microsoft.teams2")]
        coord.start()
        Thread.sleep(forTimeInterval: 0.2)   // start()'s direct initial evaluate
        check("coordinator: idle with no audio", coord.snapshot().stage == .idle)

        world.audio.procs = teamsAudio(input: true, output: true)
        settle()
        check("coordinator: input+output enters candidate, tentative capture starts",
              coord.snapshot().stage == .candidate && c.get("tent") == 1,
              "stage=\(coord.snapshot().stage) tent=\(c.get("tent"))")

        world.clock.advance(by: 3.5)
        settle()
        check("coordinator: confirmable 3.5 s promotes (onCallStart)",
              coord.snapshot().stage == .confirmed && c.get("start") == 1,
              "stage=\(coord.snapshot().stage) start=\(c.get("start"))")

        // Device swap quiescence: the coordinator stamps lastDeviceSwapAt
        // from the VirtualClock, so an input loss right after the swap
        // notification carries deviceSwapWithinLast3s and stays confirmed.
        world.device.deviceId = 43
        world.device.notify()
        world.audio.procs = []
        settle()
        check("coordinator: input loss inside swap quiescence stays confirmed",
              coord.snapshot().stage == .confirmed,
              "stage=\(coord.snapshot().stage)")

        // Past the 3 s quiescence window the loss counts: ending → idle.
        world.clock.advance(by: 4)
        settle()
        check("coordinator: loss past quiescence enters ending",
              coord.snapshot().stage == .ending, "stage=\(coord.snapshot().stage)")
        world.clock.advance(by: 31)
        settle()
        check("coordinator: grace elapsed → idle with balanced stop",
              coord.snapshot().stage == .idle && c.get("stop") == 1 && c.get("discard") == 0,
              "stage=\(coord.snapshot().stage) stop=\(c.get("stop")) discard=\(c.get("discard"))")

        // Candidate that never confirms: primary only, then lost for > 8 s.
        world.audio.procs = teamsAudio(input: true, output: false)
        settle()
        check("coordinator: primary-only re-enters candidate",
              coord.snapshot().stage == .candidate && c.get("tent") == 2,
              "stage=\(coord.snapshot().stage) tent=\(c.get("tent"))")
        world.audio.procs = []
        settle()
        world.clock.advance(by: 9)
        settle()
        check("coordinator: demoted candidate discards tentative capture, no stop",
              coord.snapshot().stage == .idle && c.get("discard") == 1
              && c.get("start") == 1 && c.get("stop") == 1,
              "discard=\(c.get("discard")) start=\(c.get("start")) stop=\(c.get("stop"))")

        coord.stop()
    }

    // 17d. Browser-Teams detection (opt-in). A browser's mic use counts as
    //      primary ONLY while its window shows a Teams meeting tab; with the
    //      flag off, browsers are invisible to the detector entirely.
    do {
        check("browser tab title: meeting tab matches",
              AXBrowserTabProvider.titleLooksLikeMeetingTab("Meeting in Weekly Sync | Microsoft Teams — Google Chrome"))
        check("browser tab title: call tab matches",
              AXBrowserTabProvider.titleLooksLikeMeetingTab("Call with David | Microsoft Teams"))
        check("browser tab title: background chat tab does not match",
              !AXBrowserTabProvider.titleLooksLikeMeetingTab("Chat | Microsoft Teams — Google Chrome"))
        check("browser tab title: unrelated meeting page does not match",
              !AXBrowserTabProvider.titleLooksLikeMeetingTab("Meeting notes - Google Docs"))

        // buildEvidence: a browser proc with input only counts when its pid
        // is in browserTabPids.
        let browserProcs = [
            AudioProcessInfo(pid: 300, bundleId: "com.google.chrome.helper",
                             isRunningInput: true, isRunningOutput: true),
        ]
        let without = DetectionCoordinator.buildEvidence(
            audio: browserProcs, now: 0, matchers: ["com.microsoft.teams2"],
            browserMatchers: ["com.google.chrome"], browserTabPids: [],
            defaultDeviceId: 42, meetingWindow: .notMatched,
            cameraPids: [], deviceSwapWithinLast3s: false)
        let with = DetectionCoordinator.buildEvidence(
            audio: browserProcs, now: 0, matchers: ["com.microsoft.teams2"],
            browserMatchers: ["com.google.chrome"], browserTabPids: [300],
            defaultDeviceId: 42, meetingWindow: .notMatched,
            cameraPids: [], deviceSwapWithinLast3s: false)
        check("buildEvidence: browser mic without meeting tab is not primary",
              !without.primarySignal && without.triggerInputPids.isEmpty)
        check("buildEvidence: browser mic + meeting tab is primary with output corroborator",
              with.primarySignal && with.triggerInputPids == [300]
              && with.corroborators.contains("output"))

        // Full coordinator lifecycle: Chrome in a Teams meeting tab confirms;
        // closing the tab (probe returns nothing) ends the call.
        final class Counters: @unchecked Sendable {
            private let lock = NSLock()
            private var counts: [String: Int] = [:]
            func bump(_ k: String) { lock.withLock { counts[k, default: 0] += 1 } }
            func get(_ k: String) -> Int { lock.withLock { counts[k] ?? 0 } }
        }
        let world = FakeDetectionWorld()
        var cfg = Config()
        cfg.detectBrowserTeams = true
        let coord = world.makeCoordinator(config: cfg)
        let c = Counters()
        coord.onCallStart = { _ in c.bump("start") }
        coord.onCallStop = { _ in c.bump("stop") }
        func settle() { world.audio.notify(); Thread.sleep(forTimeInterval: 0.45) }

        world.presence.apps = [RunningAppInfo(pid: 300, bundleId: "com.google.chrome")]
        world.audio.procs = [AudioProcessInfo(pid: 300, bundleId: "com.google.chrome.helper",
                                              isRunningInput: true, isRunningOutput: true)]
        coord.start()
        Thread.sleep(forTimeInterval: 0.2)
        check("browser coordinator: mic use with NO meeting tab stays idle",
              coord.snapshot().stage == .idle, "stage=\(coord.snapshot().stage)")

        world.tabs.pids = [300]
        settle()
        world.clock.advance(by: 3.5)
        settle()
        check("browser coordinator: meeting tab + mic + output confirms",
              coord.snapshot().stage == .confirmed && c.get("start") == 1,
              "stage=\(coord.snapshot().stage) start=\(c.get("start"))")

        world.tabs.pids = []
        settle()
        world.clock.advance(by: 31)
        settle()
        check("browser coordinator: tab closed → grace → stop",
              coord.snapshot().stage == .idle && c.get("stop") == 1,
              "stage=\(coord.snapshot().stage) stop=\(c.get("stop"))")
        coord.stop()

        // Flag off: identical world, browser never becomes a candidate.
        let world2 = FakeDetectionWorld()
        let coord2 = world2.makeCoordinator()   // detectBrowserTeams defaults false
        world2.presence.apps = [RunningAppInfo(pid: 300, bundleId: "com.google.chrome")]
        world2.audio.procs = [AudioProcessInfo(pid: 300, bundleId: "com.google.chrome.helper",
                                               isRunningInput: true, isRunningOutput: true)]
        world2.tabs.pids = [300]
        coord2.start()
        Thread.sleep(forTimeInterval: 0.2)
        world2.audio.notify()
        Thread.sleep(forTimeInterval: 0.45)
        check("browser coordinator: flag off → browser is invisible",
              coord2.snapshot().stage == .idle,
              "stage=\(coord2.snapshot().stage)")
        coord2.stop()
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
