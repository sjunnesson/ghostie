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
final class Engine: @unchecked Sendable {
    private(set) var config: Config
    private var detector: CallDetector
    private var recorder: AudioRecorder?
    private var recordingStartedAt = Date()
    private let work = DispatchQueue(label: "ghostie.pipeline")
    private let gate = DispatchQueue(label: "ghostie.gate")
    private var listening = false

    /// Called (on an arbitrary queue) whenever state changes; UI must hop to main.
    var onStateChange: ((EngineState) -> Void)?
    var onNote: ((URL) -> Void)?
    /// Fires after a backlog drain with the remaining pending count.
    var onBacklogChange: ((Int) -> Void)?
    private var backlogTimer: DispatchSourceTimer?

    private(set) var state: EngineState = .paused {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var lastNote: URL?
    private(set) var callsProcessed = 0

    init(config: Config) {
        self.config = config
        self.detector = CallDetector(config: config)
        detector.onCallStart = { [weak self] in self?.handleStart() }
        detector.onCallStop  = { [weak self] in self?.handleStop() }
    }

    var isListening: Bool { listening }

    /// Safe to replace the running .app bundle? Never mid-call or mid-summary
    /// (those would lose the recording / kill the pipeline). Advisory read of
    /// `state`, consistent with how the menu bar reads it.
    func swapIsSafe() -> Bool {
        switch state {
        case .recording, .processing: return false
        case .paused, .watching:      return true
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
        detector.onCallStart = { [weak self] in self?.handleStart() }
        detector.onCallStop  = { [weak self] in self?.handleStop() }
        if wasListening { detector.start() }
        Log.info("Settings updated\(wasListening ? " — detector restarted" : "").")
        drainBacklog()   // settings may have fixed whisper / Claude Code
    }

    func startListening() {
        guard !listening else { return }
        listening = true
        detector.start()
        state = .watching
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
        if recorder != nil { handleStop() } // finalize an in-progress call
        state = .paused
        Log.info("Listening paused.")
    }

    /// Try to process anything sitting in the backlog. Cheap when empty.
    func drainBacklog() {
        work.async {
            let done = Pipeline.drain(config: Config.load())
            let pending = Backlog.pendingCount
            if done > 0 { self.callsProcessed += done }
            self.onBacklogChange?(pending)
        }
    }

    private func handleStart() {
        gate.async {
            guard self.recorder == nil else { return }
            self.recordingStartedAt = Date()
            let rec = AudioRecorder(config: self.config)
            self.recorder = rec
            Task {
                do {
                    try await rec.start()
                    self.state = .recording(since: self.recordingStartedAt)
                } catch {
                    Log.error("Could not start recording: \(error.localizedDescription)")
                    Log.error("Grant Screen Recording + Microphone in System Settings ▸ Privacy & Security.")
                    self.gate.async { self.recorder = nil }
                    self.state = self.listening ? .watching : .paused
                }
            }
        }
    }

    private func handleStop() {
        gate.async {
            guard let rec = self.recorder else { return }
            self.recorder = nil
            let started = self.recordingStartedAt
            Task {
                // AudioRecorder.stop() returns nil for sub-`minCallSeconds`
                // calls (the in-memory ring is dropped without ever writing
                // to disk). No post-hoc disk-discard needed here.
                guard let result = await rec.stop() else {
                    self.state = self.listening ? .watching : .paused
                    return
                }
                self.state = .processing
                self.work.async {
                    let note = Pipeline(config: Config.load()).process(result, startedAt: started)
                    if let note {
                        self.lastNote = note
                        self.callsProcessed += 1
                        self.onNote?(note)
                    }
                    self.state = self.listening ? .watching : .paused
                    // Dependencies are clearly healthy now — clear any backlog.
                    let done = Pipeline.drain(config: Config.load())
                    if done > 0 { self.callsProcessed += done }
                    self.onBacklogChange?(Backlog.pendingCount)
                }
            }
        }
    }

    /// One-shot N-second capture + full pipeline (menu "Run Test"). The
    /// short-call discard is bypassed so a sub-`minCallSeconds` test still
    /// produces a note instead of silently dropping the audio.
    func runTest(seconds: Double, completion: @escaping (URL?) -> Void) {
        let rec = AudioRecorder(config: config)
        let started = Date()
        Task {
            do {
                try await rec.start()
                self.state = .recording(since: started)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let result = await rec.stop(discardIfBelowMinCallSeconds: false) else {
                    self.state = self.listening ? .watching : .paused
                    completion(nil)
                    return
                }
                self.state = .processing
                self.work.async {
                    let note = Pipeline(config: Config.load()).process(result, startedAt: started)
                    if let note { self.lastNote = note; self.onNote?(note) }
                    self.state = self.listening ? .watching : .paused
                    completion(note)
                }
            } catch {
                Log.error("Test failed: \(error.localizedDescription)")
                self.state = self.listening ? .watching : .paused
                completion(nil)
            }
        }
    }

    /// Finalize any active recording synchronously-ish before app quit.
    func shutdown(then: @escaping () -> Void) {
        if let rec = recorder {
            recorder = nil
            let started = recordingStartedAt
            Task {
                if let r = await rec.stop(), r.duration >= config.minCallSeconds {
                    work.async {
                        _ = Pipeline(config: Config.load()).process(r, startedAt: started)
                        then()
                    }
                } else { then() }
            }
        } else {
            then()
        }
    }
}
