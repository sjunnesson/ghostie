import Foundation

/// Pure state machine consuming `CallEvidence` snapshots, emitting `onCallStart`
/// / `onCallStop` at the right times. No CoreAudio, no AX, no threading; all of
/// that lives in the providers and the coordinator that wires them in.
///
/// State graph (full justification in detector-rearchitecture.md):
///
///     idle ──primary signal──> candidate
///     candidate ──confirmable for confirmSeconds──> confirmed   (onCallStart)
///     candidate ──primary lost >8s──> idle              (silent: no start fired)
///     confirmed ──primary lost──> ending
///     ending ──primary returns within endGraceSeconds──> confirmed
///     ending ──grace elapses──> idle                            (onCallStop)
///
/// `onCallStart`/`onCallStop` are a balanced pair: stop only ever fires for a
/// session that already emitted start. A candidate that demotes back to idle
/// never announced itself, so it ends silently (the transition log still
/// records the demotion).
///
/// `onTentativeStart`/`onTentativeDiscard` bracket the candidate window the
/// same way: tentative-start fires on idle → candidate so the engine can
/// begin capturing into the in-memory ring immediately (a call's opening
/// seconds would otherwise be lost to the confirm window), and discard fires
/// only for a candidate that demotes without confirming. A confirmed session
/// never emits discard — its tentative capture is simply kept.
///
/// Device-swap quiescence: when the default input device changes, the
/// coordinator marks `evidence.deviceSwapWithinLast3s = true` for 3 s; the
/// state machine then treats `primarySignal=false` as effectively true,
/// suppressing spurious `ending` transitions while audio routing reconverges.
/// The asymmetry is deliberate: quiescence only suppresses primary LOSS in
/// candidate/confirmed/ending — it never synthesizes primary PRESENCE in
/// idle (unplugging headphones at the desk must not create a candidate).
/// It is also bounded: quiescence alone can sustain a call for at most
/// 2× endGraceSeconds past the last real primary observation, so a flaky
/// device flapping faster than the 3 s window cannot hold a dead call open
/// forever (see `quiescenceSustains`).
final class CallStateMachine {

    struct Config {
        var confirmSeconds: TimeInterval = 3
        var candidatePrimaryLossTimeoutSeconds: TimeInterval = 8
        var endGraceSeconds: TimeInterval = 30
        init() {}
    }

    enum Stage: String, Equatable {
        case idle, candidate, confirmed, ending
    }

    struct Transition: Equatable {
        let from: Stage
        let to: Stage
        let at: VirtualTime
        let reason: String
        let evidence: CallEvidence
    }

    private(set) var stage: Stage = .idle
    private(set) var sessionId: UUID?
    private(set) var stageEnteredAt: VirtualTime
    private(set) var lastEvidence: CallEvidence?
    private(set) var transitions: [Transition] = []

    /// Fires when candidate is promoted to confirmed.
    var onCallStart: ((UUID) -> Void)?
    /// Fires when ending grace elapses (or forceStop() is called while a
    /// confirmed session is live). Never fires for a session that did not
    /// emit `onCallStart` — start/stop are a balanced pair.
    var onCallStop: ((UUID) -> Void)?
    /// Fires on idle → candidate: first primary evidence. The engine starts
    /// a tentative capture here so the confirm window isn't lost audio.
    var onTentativeStart: ((UUID) -> Void)?
    /// Fires when a candidate demotes to idle without ever confirming
    /// (primary lost too long, or forceStop mid-candidate). The paired
    /// tentative capture must be discarded, never processed. A session that
    /// confirmed emits `onCallStop` instead — the two are mutually exclusive.
    var onTentativeDiscard: ((UUID) -> Void)?
    /// Fires on every transition, for diagnostics and logging.
    var onTransition: ((Transition) -> Void)?

    private let clock: Clock
    private let config: Config

    /// Start of the current run of `confirmable=true` evidence (candidate only).
    private var confirmableRunStart: VirtualTime?
    /// Start of the current run of `effectivePrimary=false` evidence
    /// (candidate, confirmed, or ending).
    private var primaryFalseRunStart: VirtualTime?
    /// True once `onCallStart` has fired for the current `sessionId`.
    /// Gates `onCallStop` so a candidate that demotes without ever
    /// confirming ends silently — consumers must never see "call ended"
    /// for a call that was never announced.
    private var sessionStarted = false
    /// Time of the most recent evaluate() that observed the REAL primary
    /// signal (not swap-quiescence standing in for it). Caps how long
    /// quiescence alone may sustain a call (`quiescenceSustains`).
    private var lastRealPrimaryAt: VirtualTime?

    init(config: Config = .init(), clock: Clock) {
        self.config = config
        self.clock = clock
        self.stageEnteredAt = clock.now
    }

    /// Feed the latest evidence snapshot. Safe to call from listener callbacks
    /// or a periodic backstop; the state machine itself is single-threaded and
    /// must be serialized by the caller (the coordinator does this on its
    /// detector queue).
    func evaluate(evidence: CallEvidence) {
        let now = clock.now
        if evidence.primarySignal { lastRealPrimaryAt = now }
        let effectivePrimary = evidence.primarySignal
            || quiescenceSustains(evidence: evidence, now: now)
        lastEvidence = evidence

        switch stage {
        case .idle:
            // Deliberately the real signal, NOT effectivePrimary: swap
            // quiescence exists to ride over the input-device handoff
            // DURING a call (primary briefly drops while the audio unit
            // moves). It must never promote idle -> candidate on its own —
            // a device swap with zero Teams evidence is not a call.
            if evidence.primarySignal {
                enter(.candidate, at: now, evidence: evidence,
                      reason: "primary signal observed")
                evaluateCandidate(now: now, evidence: evidence,
                                  effectivePrimary: effectivePrimary)
            }
        case .candidate:
            evaluateCandidate(now: now, evidence: evidence,
                              effectivePrimary: effectivePrimary)
        case .confirmed:
            evaluateConfirmed(now: now, evidence: evidence,
                              effectivePrimary: effectivePrimary)
        case .ending:
            evaluateEnding(now: now, evidence: evidence,
                           effectivePrimary: effectivePrimary)
        }
    }

    /// Whether device-swap quiescence may stand in for a missing primary
    /// signal right now. Quiescence only ever *suppresses primary loss* in
    /// candidate/confirmed/ending (the idle branch checks the real signal
    /// directly), and it is capped: a flaky device cycling faster than the
    /// 3 s swap window would otherwise pin `effectivePrimary` true forever,
    /// holding a dead call in confirmed/ending indefinitely. So quiescence
    /// alone may only bridge up to 2× endGraceSeconds (60 s by default)
    /// since the last REAL primary observation — generous against any
    /// plausible device handoff, but bounded; once exceeded, the normal
    /// ending grace runs and the call closes.
    private func quiescenceSustains(evidence: CallEvidence,
                                    now: VirtualTime) -> Bool {
        guard evidence.deviceSwapWithinLast3s,
              let lastReal = lastRealPrimaryAt else { return false }
        return now - lastReal <= 2 * config.endGraceSeconds
    }

    /// Force-stop the current call (e.g. user toggled the menu bar off, or
    /// shutdown). Emits `onCallStop` if a confirmed session is live (a bare
    /// candidate clears silently), then returns to idle.
    func forceStop(reason: String = "external stop") {
        let now = clock.now
        let ev = lastEvidence ?? CallEvidence(
            timestamp: now, triggerMainPids: [], triggerInputPids: [],
            triggerOutputPids: [], triggerCameraPids: [], meetingWindow: .notMatched,
            defaultInputDeviceId: nil, deviceSwapWithinLast3s: false)
        if stage != .idle {
            enter(.idle, at: now, evidence: ev, reason: reason)
        }
    }

    // MARK: - Per-stage step

    private func evaluateCandidate(now: VirtualTime,
                                   evidence: CallEvidence,
                                   effectivePrimary: Bool) {
        // Update the two "runs" the candidate logic tracks.
        if effectivePrimary {
            primaryFalseRunStart = nil
        } else if primaryFalseRunStart == nil {
            primaryFalseRunStart = now
        }
        if evidence.confirmable {
            if confirmableRunStart == nil { confirmableRunStart = now }
        } else {
            confirmableRunStart = nil
        }

        // Demotion: primary lost for longer than the candidate's tolerance.
        // (There is no "max time in candidate" cap. While primary is on we
        // simply wait for a corroborator. Going back to idle while primary
        // stays on would re-enter candidate on the next tick — a cycle, not
        // a state. The tentative ring buffer in AudioRecorder caps the
        // memory cost.)
        if let s = primaryFalseRunStart,
           now - s >= config.candidatePrimaryLossTimeoutSeconds {
            enter(.idle, at: now, evidence: evidence,
                  reason: "candidate primary lost for >= \(format(config.candidatePrimaryLossTimeoutSeconds))s")
            return
        }
        // Promotion.
        if let s = confirmableRunStart, now - s >= config.confirmSeconds {
            let corrs = evidence.corroborators.sorted().joined(separator: ",")
            enter(.confirmed, at: now, evidence: evidence,
                  reason: "confirmable for >= \(format(config.confirmSeconds))s (corroborators: \(corrs))")
        }
    }

    private func evaluateConfirmed(now: VirtualTime,
                                   evidence: CallEvidence,
                                   effectivePrimary: Bool) {
        if effectivePrimary {
            primaryFalseRunStart = nil
        } else {
            // First false observation flips us into ending immediately; the
            // 30 s grace runs from this moment.
            primaryFalseRunStart = now
            let corrs = evidence.corroborators.sorted().joined(separator: ",")
            let detail = corrs.isEmpty ? "no corroborators" : "corroborators still: \(corrs)"
            enter(.ending, at: now, evidence: evidence,
                  reason: "primary signal lost (\(detail))")
        }
    }

    private func evaluateEnding(now: VirtualTime,
                                evidence: CallEvidence,
                                effectivePrimary: Bool) {
        // Returning primary wins over grace expiry on the same evaluate:
        // if the primary signal is back, the call is alive again, regardless
        // of how long ending has been pending. Only fall through to the
        // grace check when primary is still false.
        if effectivePrimary {
            primaryFalseRunStart = nil
            enter(.confirmed, at: now, evidence: evidence,
                  reason: "primary signal returned within grace")
            return
        }
        if now - stageEnteredAt >= config.endGraceSeconds {
            enter(.idle, at: now, evidence: evidence,
                  reason: "end grace \(format(config.endGraceSeconds))s elapsed")
        }
    }

    // MARK: - Transition

    private func enter(_ newStage: Stage, at: VirtualTime,
                       evidence: CallEvidence, reason: String) {
        let from = stage
        stage = newStage
        stageEnteredAt = at

        switch newStage {
        case .idle:
            confirmableRunStart = nil
            primaryFalseRunStart = nil
            let dead = sessionId
            let started = sessionStarted
            sessionId = nil
            sessionStarted = false
            // Stop only fires for sessions that emitted start. A demoted
            // candidate never announced itself, so it clears via
            // onTentativeDiscard (the engine throws the tentative capture
            // away); the transition (with reason) is still recorded and
            // logged via onTransition.
            if started, let s = dead {
                onCallStop?(s)
            } else if let s = dead {
                onTentativeDiscard?(s)
            }
        case .candidate:
            sessionId = UUID()
            sessionStarted = false
            confirmableRunStart = evidence.confirmable ? at : nil
            // Candidate is only ever entered on a real primary observation
            // (idle ignores swap quiescence), so no false-run is pending.
            primaryFalseRunStart = nil
            if let s = sessionId { onTentativeStart?(s) }
        case .confirmed:
            confirmableRunStart = nil
            primaryFalseRunStart = nil
            // Only emit start when this is the first promotion of this session.
            // ending -> confirmed re-entries do NOT re-fire start.
            if from == .candidate, let s = sessionId {
                sessionStarted = true
                onCallStart?(s)
            }
        case .ending:
            if primaryFalseRunStart == nil { primaryFalseRunStart = at }
        }

        let t = Transition(from: from, to: newStage, at: at, reason: reason, evidence: evidence)
        transitions.append(t)
        onTransition?(t)
    }

    private func format(_ s: TimeInterval) -> String {
        s == s.rounded() ? "\(Int(s))" : String(format: "%.1f", s)
    }
}
