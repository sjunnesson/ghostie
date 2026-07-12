import Foundation

enum EngineState: Equatable {
    case paused
    case watching
    case recording(since: Date)
    case processing

    var menuLabel: String {
        switch self {
        case .paused:     return "Paused"
        case .watching:   return "Watching for Teams calls"
        case .recording:  return "Recording call…"
        case .processing: return "Summarizing call…"
        }
    }
}

/// The detect → record → transcribe → summarize loop, decoupled from any UI so
/// it can drive both the headless `run` daemon and the menu bar app.
///
/// State is synchronized through the private `gate` and `work` dispatch queues
/// rather than the actor model, so the class manages its own thread safety and
/// is declared `@unchecked Sendable` to allow it across `@Sendable` closures.
/// Every mutable field below is owned by exactly one queue (see each comment);
/// `…Locked` helpers must only run on `gate`.
final class Engine: @unchecked Sendable {
    private(set) var config: Config
    private var detector: CallDetector
    /// The live call's recorder. Gate-only; handed off to a finalizer exactly
    /// once via `takeRecorderLocked()` (stop, fatal stream error and shutdown
    /// all race for it, whoever wins owns the stop).
    private var recorder: AudioRecorder?
    /// True while `recorder` is a tentative (candidate-stage) capture that
    /// has not been confirmed as a call. Tentative captures are invisible in
    /// `EngineState` (the icon stays "watching") and are discarded — never
    /// processed — if the candidate demotes. Gate-only.
    private var isTentative = false
    /// The in-flight `AudioRecorder.start()` for `recorder`. Finalizers await
    /// it before taking the recorder, so a stop can never slip inside the
    /// SCShareableContent/startCapture window and orphan a live SCStream.
    /// Gate-only.
    private var startTask: Task<Void, Never>?
    /// "Run Test" capture — kept out of `recorder` so the detector's stop
    /// can't cut a fixed-length test short. Gate-only.
    private var testRecorder: AudioRecorder?
    private var recordingStartedAt = Date()   // gate-only
    /// Recordings currently on (or queued for) the `work` pipeline. Gate-only;
    /// lets `settleStateLocked()` / `swapIsSafe()` see pipeline work even when
    /// a new call has started while the previous one is still summarizing.
    private var processingCount = 0
    private let work = DispatchQueue(label: "ghostie.pipeline")
    private let gate = DispatchQueue(label: "ghostie.gate")
    private var listening = false
    /// Flipped on `work` (serial) so the orphan sweep runs exactly once.
    private var orphanSweepDone = false

    /// Called (on an arbitrary queue) whenever state changes; UI must hop to main.
    var onStateChange: ((EngineState) -> Void)?
    var onNote: ((URL) -> Void)?
    /// Fires after a backlog drain with the remaining pending count.
    var onBacklogChange: ((Int) -> Void)?
    private var backlogTimer: DispatchSourceTimer?

    /// Backing store for `state`. Gate-only, like every other mutable field;
    /// always written through `setStateLocked` / `settleStateLocked`.
    private var _state: EngineState = .paused
    /// Snapshot for UI readers (menu bar tick, Settings). Hops through `gate`
    /// so a read can never tear against a transition on another queue.
    var state: EngineState { gate.sync { _state } }
    private(set) var lastNote: URL?        // mutated on `work` only (serial)
    private(set) var callsProcessed = 0    // mutated on `work` only (serial)

    init(config: Config) {
        self.config = config
        self.detector = CallDetector(config: config)
        wireDetector()
    }

    /// The four detector callbacks, shared by init and applyConfig. Tentative
    /// start/discard bracket the candidate window so the confirm window's
    /// audio (a call's opening seconds) is captured, not lost.
    private func wireDetector() {
        detector.onCallStart = { [weak self] in self?.handleStart() }
        detector.onCallStop  = { [weak self] in self?.handleStop() }
        detector.onTentativeStart = { [weak self] in self?.handleTentativeStart() }
        detector.onTentativeDiscard = { [weak self] in self?.handleStop() }
    }

    var isListening: Bool { listening }

    // MARK: Gate-only helpers

    /// Replaces the old stored-property `didSet`: fires `onStateChange` only
    /// on an actual transition. Must run on `gate`.
    private func setStateLocked(_ new: EngineState) {
        guard new != _state else { return }
        _state = new
        onStateChange?(new)
    }

    /// Recompute `state` from current reality rather than last-writer-wins:
    /// once calls overlap, a finishing pipeline must not stomp `.watching`
    /// over a recording that started while it was busy (which also flipped
    /// `swapIsSafe()` true and let the auto-updater relaunch mid-call).
    /// Must run on `gate`.
    private func settleStateLocked() {
        if (recorder != nil && !isTentative) || testRecorder != nil {
            setStateLocked(.recording(since: recordingStartedAt))
        } else if processingCount > 0 {
            setStateLocked(.processing)
        } else {
            // A tentative (unconfirmed-candidate) capture deliberately reads
            // as "watching": most candidates confirm within ~3 s, and one
            // that demotes was never a call — the icon should not flicker
            // "recording" for it.
            setStateLocked(listening ? .watching : .paused)
        }
    }

    /// Exactly-once handoff of the live recorder (+ its start date) to a
    /// finalizer. Idempotent by construction — the second caller gets nil —
    /// which is what makes stop / fatal-stream-error / shutdown safe to race.
    /// Must run on `gate`.
    private func takeRecorderLocked() -> (rec: AudioRecorder, startedAt: Date, tentative: Bool)? {
        guard let rec = recorder else { return nil }
        recorder = nil
        let tentative = isTentative
        isTentative = false
        return (rec, recordingStartedAt, tentative)
    }

    /// Safe to replace the running .app bundle? Never mid-call or mid-summary
    /// (those would lose the recording / kill the pipeline). Checked through
    /// `gate` against current reality — recorder presence, an in-flight
    /// start, queued pipeline work — not the cached enum, which can lag one
    /// transition behind when calls overlap.
    func swapIsSafe() -> Bool {
        gate.sync {
            recorder == nil && testRecorder == nil
                && startTask == nil && processingCount == 0
        }
    }

    /// Swap in a new configuration at runtime (from the Settings window).
    /// Recording/transcription/summary already reload `Config.load()` per call;
    /// the detector is rebuilt here so detection settings take effect too.
    func applyConfig(_ newConfig: Config) {
        let wasListening = listening
        if wasListening { detector.stop() }
        config = newConfig
        detector = CallDetector(config: newConfig)
        wireDetector()
        if wasListening { detector.start() }
        Log.info("Settings updated\(wasListening ? " — detector restarted" : "").")
        drainBacklog()   // settings may have fixed whisper / Claude Code
    }

    func startListening() {
        guard !listening else { return }
        listening = true
        detector.start()
        gate.async { self.settleStateLocked() }
        Log.ok("Listening for Teams calls (no bot joins your meetings).")
        drainBacklog()   // catch up on anything queued while we were away
        let t = DispatchSource.makeTimerSource(queue: gate)
        t.schedule(deadline: .now() + 600, repeating: 600)   // retry every 10 min
        t.setEventHandler { [weak self] in self?.drainBacklog() }
        t.resume()
        backlogTimer = t
    }

    func stopListening() {
        guard listening else { return }
        listening = false
        detector.stop()
        backlogTimer?.cancel(); backlogTimer = nil
        handleStop()   // finalize an in-progress call (no-op when idle)
        gate.async { self.settleStateLocked() }
        Log.info("Listening paused.")
    }

    /// Try to process anything sitting in the backlog. The empty case — every
    /// 10-min timer tick, normally — is answered by one directory listing
    /// (`Backlog.isEmpty`) before `Config.load()` (which stats binaries and
    /// re-reads the model catalog) or any entry parsing happens.
    func drainBacklog() {
        work.async {
            // One-shot launch sweep, sequenced on this same serial queue so
            // it always lands before the first drain: recording dirs orphaned
            // by a crash/kill mid-call would otherwise sit in workDir forever.
            if !self.orphanSweepDone {
                self.orphanSweepDone = true
                let swept = Pipeline.sweepOrphanedRecordings(config: Config.load())
                if swept > 0 { Log.info("Recovered \(swept) orphaned recording(s) from a previous run.") }
            }
            guard !Backlog.isEmpty else {
                self.onBacklogChange?(0)
                return
            }
            let done = Pipeline.drain(config: Config.load())
            let pending = Backlog.pendingCount
            if done > 0 { self.callsProcessed += done }
            self.onBacklogChange?(pending)
        }
    }

    /// Candidate stage: first primary evidence. Start capturing now — into
    /// AudioRecorder's in-memory ring — so the ~3 s confirm window (the
    /// call's opening words) is part of the recording when the candidate
    /// confirms. Nothing is announced yet; a demotion discards it all.
    private func handleTentativeStart() {
        startRecorderLocked(tentative: true)
    }

    /// Confirmed call. Normally the tentative capture is already running and
    /// is simply adopted (recordingStartedAt keeps the tentative start, so
    /// the menu timer matches the audio). Falls back to a fresh start when
    /// no tentative capture exists — e.g. its start() failed.
    private func handleStart() {
        startRecorderLocked(tentative: false)
    }

    private func startRecorderLocked(tentative: Bool) {
        gate.async {
            if self.recorder != nil {
                // Confirm adopting the live tentative capture; duplicate
                // starts are otherwise ignored (same as before).
                if !tentative && self.isTentative {
                    self.isTentative = false
                    self.settleStateLocked()   // → .recording
                }
                return
            }
            self.isTentative = tentative
            self.recordingStartedAt = Date()
            let rec = AudioRecorder(config: self.config)
            self.recorder = rec
            // Stream death mid-call (display sleep, permission revoked, SCK
            // error): finalize through the normal stop path so the audio
            // captured so far still becomes a note instead of accumulating
            // nothing behind a stuck "Recording…". handleStop takes the
            // recorder through `gate` exactly once, so the detector's own
            // onCallStop firing later is a harmless no-op. (For a tentative
            // capture the same path discards instead of processing.)
            rec.onFatalError = { [weak self] in self?.handleStop() }
            self.startTask = Task {
                do {
                    try await rec.start()
                } catch {
                    Log.error("Could not start recording: \(error.localizedDescription)")
                    Log.error("Grant Screen Recording + Microphone in System Settings ▸ Privacy & Security.")
                    self.gate.async {
                        if self.recorder === rec {
                            self.recorder = nil
                            self.isTentative = false
                        }
                    }
                }
                self.gate.async {
                    self.startTask = nil
                    self.settleStateLocked()   // .recording on success, idle on failure
                }
            }
        }
    }

    private func handleStop() {
        gate.async {
            guard self.recorder != nil else { return }
            let pendingStart = self.startTask
            Task {
                // An in-flight start() may still be awaiting SCShareableContent
                // or startCapture (a 1–2 s window). Stopping through it would
                // find a nil stream, skip stopCapture, and leave a live
                // SCStream recording with no owner — so wait the start out
                // before taking the recorder.
                await pendingStart?.value
                // Exactly-once handoff: a concurrent finalizer (onFatalError,
                // shutdown, a duplicate onCallStop) loses this race and just
                // returns.
                guard let (rec, started, tentative) = (self.gate.sync { self.takeRecorderLocked() })
                else { return }
                if tentative {
                    // Candidate demoted without confirming: this was never a
                    // call. Discard everything — usually just the in-memory
                    // ring, but a long-lived candidate may have flushed to
                    // disk, so remove the session dir too.
                    if let r = await rec.stop(discardIfBelowMinCallSeconds: false) {
                        try? FileManager.default.removeItem(at: r.sessionDir)
                    }
                    self.gate.async { self.settleStateLocked() }
                    return
                }
                // AudioRecorder.stop() returns nil for sub-`minCallSeconds`
                // calls (the in-memory ring is dropped without ever writing
                // to disk). No post-hoc disk-discard needed here.
                guard let result = await rec.stop() else {
                    self.gate.async { self.settleStateLocked() }
                    return
                }
                // The work block is enqueued from inside the gate block so
                // the count is visibly nonzero before the pipeline can start
                // (otherwise swapIsSafe() has a microsecond window of "idle").
                self.gate.async {
                    self.processingCount += 1
                    self.settleStateLocked()
                    self.work.async {
                        let note = Pipeline(config: Config.load()).process(result, startedAt: started)
                        if let note {
                            self.lastNote = note
                            self.callsProcessed += 1
                            self.onNote?(note)
                        }
                        // Dependencies are clearly healthy now — clear any backlog.
                        let done = Pipeline.drain(config: Config.load())
                        if done > 0 { self.callsProcessed += done }
                        self.onBacklogChange?(Backlog.pendingCount)
                        self.gate.async {
                            self.processingCount -= 1
                            self.settleStateLocked()
                        }
                    }
                }
            }
        }
    }

    /// One-shot N-second capture + full pipeline (menu "Run Test"). The
    /// short-call discard is bypassed so a sub-`minCallSeconds` test still
    /// produces a note instead of silently dropping the audio. Refused while
    /// a real call is live (or starting) — a second concurrent SCStream would
    /// clobber the live call.
    func runTest(seconds: Double, completion: @escaping (URL?) -> Void) {
        let started = Date()
        let rec: AudioRecorder? = gate.sync {
            var busy = recorder != nil || startTask != nil || testRecorder != nil
            if case .recording = _state { busy = true }
            guard !busy else { return nil }
            let r = AudioRecorder(config: config)
            testRecorder = r
            recordingStartedAt = started
            return r
        }
        guard let rec else {
            Log.warn("Test recording refused — a call is being recorded right now.")
            completion(nil)
            return
        }
        Task {
            do {
                try await rec.start()
                self.gate.async { self.settleStateLocked() }   // → .recording
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let result = await rec.stop(discardIfBelowMinCallSeconds: false) else {
                    self.gate.async { self.testRecorder = nil; self.settleStateLocked() }
                    completion(nil)
                    return
                }
                // Work enqueued from inside the gate block, same as
                // handleStop: the count must be nonzero before the pipeline
                // can start.
                self.gate.async {
                    self.testRecorder = nil
                    self.processingCount += 1
                    self.settleStateLocked()
                    self.work.async {
                        let note = Pipeline(config: Config.load()).process(result, startedAt: started)
                        if let note { self.lastNote = note; self.onNote?(note) }
                        self.gate.async {
                            self.processingCount -= 1
                            self.settleStateLocked()
                        }
                        completion(note)
                    }
                }
            } catch {
                Log.error("Test failed: \(error.localizedDescription)")
                self.gate.async { self.testRecorder = nil; self.settleStateLocked() }
                completion(nil)
            }
        }
    }

    /// Finalize any active recording synchronously-ish before app quit.
    /// Hops through `gate` (this used to poke `recorder` straight from the
    /// caller's thread, racing handleStart/handleStop) and waits out an
    /// in-flight start exactly like handleStop does.
    func shutdown(then: @escaping () -> Void) {
        gate.async {
            guard self.recorder != nil else { then(); return }
            let pendingStart = self.startTask
            Task {
                await pendingStart?.value
                guard let (rec, started, tentative) = (self.gate.sync { self.takeRecorderLocked() })
                else { then(); return }
                if tentative {
                    // Quit during an unconfirmed candidate: not a call.
                    if let r = await rec.stop(discardIfBelowMinCallSeconds: false) {
                        try? FileManager.default.removeItem(at: r.sessionDir)
                    }
                    then()
                    return
                }
                if let r = await rec.stop(), r.duration >= self.config.minCallSeconds {
                    self.work.async {
                        _ = Pipeline(config: Config.load()).process(r, startedAt: started)
                        then()
                    }
                } else { then() }
            }
        }
    }
}
