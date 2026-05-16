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
final class Engine {
    let config: Config
    private let detector: CallDetector
    private var recorder: AudioRecorder?
    private var recordingStartedAt = Date()
    private let work = DispatchQueue(label: "ghostie.pipeline")
    private let gate = DispatchQueue(label: "ghostie.gate")
    private var listening = false

    /// Called (on an arbitrary queue) whenever state changes; UI must hop to main.
    var onStateChange: ((EngineState) -> Void)?
    var onNote: ((URL) -> Void)?

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

    func startListening() {
        guard !listening else { return }
        listening = true
        detector.start()
        state = .watching
        Log.ok("Listening for Teams calls (no bot joins your meetings).")
    }

    func stopListening() {
        guard listening else { return }
        listening = false
        detector.stop()
        if recorder != nil { handleStop() } // finalize an in-progress call
        state = .paused
        Log.info("Listening paused.")
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
                guard let result = await rec.stop() else {
                    self.state = self.listening ? .watching : .paused
                    return
                }
                if result.duration < self.config.minCallSeconds {
                    Log.info("Call too short (\(Int(result.duration))s) — discarding.")
                    try? FileManager.default.removeItem(at: result.sessionDir)
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
                }
            }
        }
    }

    /// One-shot N-second capture + full pipeline (menu "Run Test").
    func runTest(seconds: Double, completion: @escaping (URL?) -> Void) {
        let rec = AudioRecorder(config: config)
        let started = Date()
        Task {
            do {
                try await rec.start()
                self.state = .recording(since: started)
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard let result = await rec.stop() else { completion(nil); return }
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
