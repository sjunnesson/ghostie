import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Records a Teams call entirely locally — no bot joins the meeting.
///
/// Two independent audio paths:
///   • SCK `.audio` → everything the system plays       = the other participants
///   • `MicCapture` (echo-cancelled voice-processing I/O), falling back to the
///     raw SCK `.microphone` tap → the local microphone = me
///
/// We keep them as two separate 16 kHz mono WAV files so the transcripts can be
/// labelled by speaker ("Me" vs "Participants") without any diarization model.
///
/// Thread safety is manual (like `Engine`): the `Lifecycle` state machine is
/// guarded by `stateLock`, sample paths by the serial queues — hence
/// `@unchecked Sendable` so the recorder can cross `@Sendable` closures.
final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {

    struct Result {
        let sessionDir: URL
        let micWav: URL
        let systemWav: URL
        let duration: Double
    }

    private let config: Config
    private var stream: SCStream?
    /// Voice-processed (echo-cancelled) mic path; nil means the raw SCK
    /// `.microphone` tap is in use (config opt-out or VP failed to start).
    private var micCapture: MicCapture?
    private var sessionDir: URL!
    private var micWriter: WavWriter?
    private var systemWriter: WavWriter?
    private let micConverter = AudioChunkConverter()
    private let systemConverter = AudioChunkConverter()
    private let audioQueue = DispatchQueue(label: "ghostie.audio")
    private let micQueue = DispatchQueue(label: "ghostie.mic")
    private let videoQueue = DispatchQueue(label: "ghostie.video")
    /// Serializes all buffer-state mutations from both audioQueue and micQueue.
    private let bufferQueue = DispatchQueue(label: "ghostie.recordbuffer")
    private(set) var startedAt = Date()

    // MARK: - Lifecycle state machine
    //
    // stop() can race start(): the detector may end a call while start() is
    // still awaiting `SCShareableContent`/`startCapture`. Before this state
    // machine existed, stop() would read a nil `stream`, skip stopCapture,
    // and the capture would later complete with no owner — recording forever.
    // Every transition now happens under `stateLock`, so exactly one side
    // owns the SCStream teardown:
    //
    //   idle ──start()──▶ starting ──▶ running ──stop()──▶ stopping ──▶ stopped
    //                        │
    //                        └─ stop() during `starting` parks on a
    //                           continuation; start() sees the flag right
    //                           after startCapture returns, tears the stream
    //                           down itself, then resumes the parked stop().
    private enum Lifecycle {
        case idle       // constructed, start() not yet called
        case starting   // inside start(), capture not yet settled
        case running    // capture live
        case stopping   // teardown in progress (owned by stop() or a
                        // cancelled start())
        case stopped    // capture down; stop() may still be finalizing files
    }
    private let stateLock = NSLock()
    private var lifecycle: Lifecycle = .idle
    /// Set by stop() if it arrives while `lifecycle == .starting`.
    private var stopRequestedDuringStart = false
    /// stop() calls parked until the in-flight start() settles.
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var fatalErrorFired = false

    /// Fired at most once, on an arbitrary queue, when capture dies while the
    /// recorder believes it is running — SCK stream error (display sleep,
    /// permission revocation) or a WAV file that can no longer be written
    /// (disk full). Never fired by a normal stop(). The engine responds by
    /// finalizing through the regular stop() path, which is safe on a dead
    /// stream: queues still drain and whatever audio was captured survives.
    var onFatalError: (() -> Void)?

    // MARK: - In-memory ring buffer
    //
    // For the first `bufferCapSeconds` of capture, PCM samples accumulate in
    // memory rather than hitting disk. If the recording ends before that cap
    // *and* the buffered duration is shorter than `config.minCallSeconds`, no
    // .wav file is ever written: the session dir is removed and we return nil
    // from stop(). Otherwise the buffer flushes to disk (existing
    // `WavWriter`s) and subsequent samples stream straight through.
    //
    // Cap is `max(30, minCallSeconds)` so a recording that crosses
    // minCallSeconds always has enough buffer to defer the disk write past
    // the discard threshold; that is the property that keeps the
    // "sub-threshold recordings never touch disk" promise honest.
    private var bufferedMicSamples: [[Int16]] = []
    private var bufferedSystemSamples: [[Int16]] = []
    private var bufferedMicFrames: Int = 0
    private var bufferedSystemFrames: Int = 0
    private var flushedToDisk = false
    private let outputSampleRate = 16000
    private var bufferCapSeconds: Double { max(30, config.minCallSeconds) }

    // MARK: - PTS anchoring
    //
    // Buffers used to be appended assuming gapless delivery, so a dropped
    // buffer or a converter failure silently time-shifted the rest of the
    // track — corrupting the cross-track merge order on long calls. Each
    // track is now anchored to the presentation timestamp of its first
    // buffer; if the accumulated sample count falls more than ~100 ms behind
    // the PTS-derived position, silence is inserted to re-align. Small leads
    // are normal clock jitter and audio is never dropped for being early.
    private struct TrackAnchor {
        var firstPTS: Double?
        /// 16 kHz samples accounted to this track since `firstPTS` — real
        /// audio plus realignment silence. Excludes the flush-time pre-pad,
        /// which represents time *before* the anchor.
        var samples = 0
    }
    private var micAnchor = TrackAnchor()
    private var systemAnchor = TrackAnchor()
    /// ~100 ms at the output rate; lags beyond this get silence-padded.
    private var maxLagSamples: Int { outputSampleRate / 10 }

    // MARK: - Mic liveness watchdog
    //
    // A capture path can fail *silently*: `AVAudioEngine` stops its graph on a
    // device change and keeps handing back buffers of digital zeros, and the
    // SCK tap does the same when the input device disappears. Nothing throws,
    // conversion succeeds, the WAV keeps pace with wall-clock — and an hour
    // later the "Me" track is an hour of silence. That is precisely how the
    // 2026-08-24 call lost 82% of the local speaker.
    //
    // The test is "this track has never produced a single non-zero sample",
    // not "the track is quiet right now": a live mic always carries a noise
    // floor, so digital silence means a dead graph, while a listener who has
    // genuinely said nothing for a minute still breathes into a working one.
    // Escalation, all gated on the *other* track actually receiving audio so
    // a silent room or a paused call never trips it:
    //
    //   ~3 s  (before the SCK stream is even built) → don't use VP at all,
    //         configure the raw SCK mic tap instead. Free: nothing recorded yet.
    //   60 s  → rebuild the voice-processing graph against the current device.
    //   150 s → give up on VP; switch the live SCStream to the raw mic tap.
    //           Echo may return, and `EchoSuppressor` handles that at text level.
    //   300 s → nothing works (permission, hardware); say so once, loudly.
    //
    /// Guards the two liveness latches, which are written from the sample
    /// queues and read from the watchdog queue and stop().
    private let signalLock = NSLock()
    private var micEverHadSignal = false
    private var systemEverHadSignal = false

    private var watchdog: DispatchSourceTimer?
    private let watchdogQueue = DispatchQueue(label: "ghostie.mic.watchdog")
    /// Retained so the watchdog can flip `captureMicrophone` and re-apply it.
    private var streamConfig: SCStreamConfiguration?
    private var micEscalation = 0
    private var deadMicReported = false

    /// How long to wait at startup for the voice-processed path to prove it
    /// is alive. A healthy graph latches on its first buffer (~20 ms), so this
    /// only ever costs time on a call that was about to lose its mic anyway.
    private let micProbeSeconds: Double = 3.0
    /// A live mic latches on its *first* buffer — an ADC always carries dither
    /// and room noise, so exact zeros eight buffers running is not a quiet
    /// room, it is a dead source. (A starved voice-processing unit trickles
    /// buffers at ~100 ms rather than the usual ~21 ms, so counting buffers
    /// rather than seconds is what keeps this decision quick.) Deciding early
    /// costs echo at worst, which the transcript's echo guard removes;
    /// deciding late costs head off the front of the "Me" track.
    private let micProbeMinBuffers = 8
    /// A live graph delivers its first buffer within ~100 ms of `start()`.
    /// Silence past this with *nothing at all* arriving is the other shape of
    /// the same failure, and waiting out the full window only costs the "Me"
    /// track more head. Generous enough to let a Bluetooth device finish
    /// negotiating, since the price of deciding early is echo (recoverable),
    /// not silence (not).
    private let micProbeNoBufferSeconds: Double = 1.25
    /// Head deliberately given up while probing, so the flush-time desync
    /// check does not report our own choice as a symptom.
    private var micProbeDelaySeconds: Double = 0
    private let micRebuildAfterSeconds: Double = 60
    private let micFallbackAfterSeconds: Double = 150
    private let micDeadAfterSeconds: Double = 300

    init(config: Config) {
        self.config = config
    }

    /// Requests permissions and starts capture. Throws if it cannot start.
    /// If stop() arrives while this is still in flight, the stream is torn
    /// down here immediately after `startCapture` returns and this returns
    /// normally — nothing is leaked regardless of caller ordering.
    func start() async throws {
        try stateLock.withLock {
            guard lifecycle == .idle else {
                throw NSError(domain: "ghostie", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "AudioRecorder.start() called more than once."])
            }
            lifecycle = .starting
        }

        do {
            try await beginCapture()
        } catch {
            // Settle the state machine so a stop() parked on `.starting`
            // (or one yet to come) sees a clean, fully-down recorder.
            stopMicCapture()
            finishStart(as: .stopped)
            throw error
        }
    }

    private func stopMicCapture() {
        micCapture?.stop()
        micCapture = nil
    }

    // MARK: - Mic liveness

    /// Waits (bounded) for the voice-processed path to deliver its first
    /// non-zero sample. Returns false if it only ever produced digital
    /// silence, which means the graph is dead and the raw tap should be used.
    private func awaitMicSignal(_ cap: MicCapture) async -> Bool {
        let began = Date()
        let deadline = began.addingTimeInterval(micProbeSeconds)
        defer { micProbeDelaySeconds = Date().timeIntervalSince(began) }
        while !cap.hasEverHadSignal, Date() < deadline {
            // Nothing arriving at all is the second shape of a dead graph.
            if cap.deliveredBuffers == 0,
               Date().timeIntervalSince(began) >= micProbeNoBufferSeconds {
                return false
            }
            // Decide as soon as enough empty buffers have arrived rather than
            // burning the whole window: the "Me" track starts when this
            // returns, and every millisecond spent here is a millisecond it
            // has to be silence-padded to stay aligned with "Participants".
            if cap.deliveredBuffers >= micProbeMinBuffers { return false }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return cap.hasEverHadSignal
    }

    /// Latches "this track has carried real audio". Written from the sample
    /// queues; the scan costs one pass over the first non-silent buffer and
    /// nothing thereafter. Realignment padding bypasses this (it is appended
    /// below `ingest*`), so inserted silence can never latch a dead track.
    private func noteSignal(_ samples: [Int16], mic: Bool) {
        let already = signalLock.withLock { mic ? micEverHadSignal : systemEverHadSignal }
        guard !already, samples.contains(where: { $0 != 0 }) else { return }
        signalLock.withLock {
            if mic { micEverHadSignal = true } else { systemEverHadSignal = true }
        }
    }

    /// Re-anchors the "Me" track's PTS clock after the mic source changes.
    /// A new source starts a fresh timeline, so without this the next buffer
    /// would look hours late and `realignmentPaddingLocked` would inject a
    /// correspondingly enormous block of silence.
    private func reanchorMicTrack() {
        bufferQueue.async { [self] in micAnchor = TrackAnchor() }
    }

    private func startMicWatchdog() {
        watchdogQueue.async { [self] in
            let t = DispatchSource.makeTimerSource(queue: watchdogQueue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in self?.checkMicLiveness() }
            watchdog = t
            t.resume()
        }
    }

    private func stopMicWatchdog() {
        watchdogQueue.sync {
            watchdog?.cancel()
            watchdog = nil
        }
    }

    /// Runs on `watchdogQueue` every 5 s until the "Me" track proves itself.
    /// See the escalation ladder documented with the liveness state above.
    private func checkMicLiveness() {
        let (micOK, sysOK) = signalLock.withLock {
            (micEverHadSignal, systemEverHadSignal)
        }
        if micOK {
            if micEscalation > 0 { Log.ok("'Me' track is receiving audio again.") }
            watchdog?.cancel()
            watchdog = nil
            return
        }
        // Gate on the other track: before it has heard anything there is no
        // call to speak into, and a silent room must never trip an escalation.
        guard sysOK else { return }
        let elapsed = Date().timeIntervalSince(startedAt)

        if micEscalation == 0, elapsed >= micRebuildAfterSeconds {
            if let cap = micCapture {
                micEscalation = 1
                Log.warn("'Me' track has recorded only digital silence for \(Int(elapsed))s while the call has audio — rebuilding the voice-processing mic graph.")
                cap.restart(reason: "the 'Me' track is recording silence")
            } else {
                // Already on the raw tap; there is nothing left to fall back
                // to, so skip straight to the terminal report.
                micEscalation = 2
                Log.warn("'Me' track has recorded only digital silence for \(Int(elapsed))s while the call has audio — the raw microphone tap is delivering no signal. Check the selected input device and Microphone permission.")
            }
            return
        }
        if micEscalation == 1, elapsed >= micFallbackAfterSeconds {
            micEscalation = 2
            switchToRawMicTap()
            return
        }
        if micEscalation < 3, elapsed >= micDeadAfterSeconds {
            micEscalation = 3
            if !deadMicReported {
                deadMicReported = true
                Log.error("'Me' track has recorded no audio at all after \(Int(elapsed))s — this call will be transcribed from the other participants only. Check System Settings ▸ Privacy & Security ▸ Microphone, and which input device is selected.")
            }
            watchdog?.cancel()
            watchdog = nil
        }
    }

    /// Last resort: drop voice processing and switch the *live* SCStream over
    /// to its raw microphone tap. Echo can return on the "Me" track — that is
    /// what `EchoSuppressor` is for, and a track with echo is recoverable
    /// where a silent one is not.
    private func switchToRawMicTap() {
        guard let cap = micCapture else { return }
        guard let cfg = streamConfig,
              let s = stateLock.withLock({ stream }) else {
            Log.error("'Me' track is silent and the raw microphone tap is unavailable — the local side of this call cannot be recovered.")
            return
        }
        Log.warn("Voice-processed mic still silent after \(Int(micFallbackAfterSeconds))s and \(cap.rebuildCount) rebuild(s) — switching the 'Me' track to the raw ScreenCaptureKit tap. Speaker echo may appear on that track; the transcript's echo guard removes it.")
        cap.stop()
        micCapture = nil
        cfg.captureMicrophone = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await s.updateConfiguration(cfg)
                self.reanchorMicTrack()
                Log.info("'Me' track switched to the raw microphone tap.")
            } catch {
                Log.error("Could not switch the 'Me' track to the raw microphone tap: \(error.localizedDescription).")
            }
        }
    }

    private func beginCapture() async throws {
        startedAt = Date()

        // Microphone permission (prompts on first run; attributed to the host
        // terminal/launchd context for an unsigned CLI).
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        if !micOK { Log.warn("Microphone access not granted — 'Me' track will be silent.") }

        let stamp = Self.stampFormatter.string(from: startedAt)
        sessionDir = URL(fileURLWithPath: config.workDir).appendingPathComponent(stamp)
        // Session dir creation is deferred to the first disk flush — keeps
        // discarded short recordings from leaving empty directories behind.

        // Triggers Screen Recording permission on first run.
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "ghostie", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture."])
        }

        let filter = SCContentFilter(display: display,
                                     excludingApplications: [],
                                     exceptingWindows: [])

        // Prefer the echo-cancelled mic path (see MicCapture). Routed through
        // micQueue so the drain fences in stop() cover it exactly like the
        // SCK tap they replace. Falls back to the raw tap on any VP failure.
        if config.micEchoCancellation && micOK {
            let cap = MicCapture { [weak self] samples, pts in
                guard let self else { return }
                self.micQueue.async { self.ingestMic(samples, pts: pts) }
            }
            cap.onRebuilt = { [weak self] in self?.reanchorMicTrack() }
            do {
                try cap.start()
                micCapture = cap
            } catch {
                Log.warn("Voice-processed mic unavailable (\(error.localizedDescription)) — falling back to the raw ScreenCaptureKit tap; expect speaker echo on the 'Me' track without headphones.")
            }
        }

        // `start()` returning is not proof of a working graph — a stopped
        // AVAudioEngine hands back well-formed buffers of zeros. Wait for the
        // first non-zero sample before committing; a healthy mic latches
        // immediately on its noise floor, so this is normally instant.
        if let cap = micCapture, await !awaitMicSignal(cap) {
            let shape = cap.deliveredBuffers == 0
                ? "delivered no audio buffers at all"
                : "delivered \(cap.deliveredBuffers) buffers of digital silence"
            Log.warn("Voice-processed mic \(shape) in \(String(format: "%.2f", micProbeDelaySeconds))s (dead audio graph, a muted/absent input device, or another app holding voice processing on it) — falling back to the raw ScreenCaptureKit tap; expect speaker echo on the 'Me' track without headphones.")
            cap.stop()
            micCapture = nil
            micQueue.sync { }
            reanchorMicTrack()
        } else if micCapture != nil {
            Log.info("Mic capture: voice-processed (echo-cancelled), signal confirmed.")
        }

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        // macOS 15+ raw mic tap. Off while the voice-processed path is
        // healthy; the watchdog flips it on via `updateConfiguration` if that
        // path turns out to be recording silence.
        cfg.captureMicrophone = micCapture == nil
        // Minimal video — required to keep the stream alive; frames are dropped.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 6
        cfg.showsCursor = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        // Registered unconditionally: with `captureMicrophone == false` no
        // buffers are delivered, and having the handler already in place makes
        // the watchdog's mid-call switch a config update rather than a stream
        // rebuild. Non-fatal if the OS refuses it — we simply lose the ability
        // to fall back, which is strictly better than failing to record.
        do {
            try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
        } catch {
            Log.warn("Could not register the raw microphone tap (\(error.localizedDescription)) — the 'Me' track cannot fall back if voice processing fails.")
        }
        streamConfig = cfg
        try await s.startCapture()

        // Publish the live stream atomically — unless stop() arrived while we
        // were awaiting above, in which case we own the teardown ourselves.
        let cancelled = stateLock.withLock { () -> Bool in
            if stopRequestedDuringStart {
                lifecycle = .stopping
                return true
            }
            stream = s
            lifecycle = .running
            return false
        }
        if cancelled {
            try? await s.stopCapture()
            stopMicCapture()
            finishStart(as: .stopped)
            Log.info("stop() arrived during startup — capture torn down immediately.")
            return
        }
        Log.ok("Recording → \(sessionDir.path)")
        startMicWatchdog()
    }

    /// Settles the state machine after start() finishes (success was already
    /// published inline; this handles the failure/cancelled paths) and wakes
    /// any stop() parked on the in-flight start.
    private func finishStart(as final: Lifecycle) {
        let waiters: [CheckedContinuation<Void, Never>] = stateLock.withLock {
            lifecycle = final
            let w = startWaiters
            startWaiters.removeAll()
            return w
        }
        for w in waiters { w.resume() }
    }

    /// Stops capture, finalizes the WAV files and returns their locations.
    /// Returns nil if the recording was shorter than `config.minCallSeconds`
    /// and the buffer never flushed to disk (the in-memory PCM is dropped
    /// and the session dir, if any, is removed). Replaces the post-hoc
    /// Engine-side `minCallSeconds` discard.
    ///
    /// Safe to call at any point in the lifecycle: during an in-flight
    /// start() it waits for the start to settle (the stream is torn down on
    /// the start side) before finalizing, and on a dead stream it still
    /// drains the queues and closes the WAVs so captured audio survives.
    ///
    /// Pass `discardIfBelowMinCallSeconds: false` for explicit-test paths
    /// (`Engine.runTest`, `test-record`) where the user wants the captured
    /// audio regardless of the short-call guard.
    func stop(discardIfBelowMinCallSeconds: Bool = true) async -> Result? {
        await tearDownCapture()
        // Fence in three stages: drain the SCK sample-handler queues so all
        // in-flight `didOutputSampleBuffer` callbacks have run, *then* drain
        // bufferQueue so the `bufferQueue.async` blocks those callbacks
        // enqueued have all completed. Without the first two, a tail SCK
        // callback could land on bufferQueue after we've already decided
        // what to do with the recording.
        audioQueue.sync { }
        micQueue.sync { }
        bufferQueue.sync { }

        if !flushedToDisk {
            let micDur = Double(bufferedMicFrames) / Double(outputSampleRate)
            let sysDur = Double(bufferedSystemFrames) / Double(outputSampleRate)
            let dur = max(micDur, sysDur)
            if discardIfBelowMinCallSeconds && dur < config.minCallSeconds {
                bufferQueue.sync {
                    bufferedMicSamples.removeAll(keepingCapacity: false)
                    bufferedSystemSamples.removeAll(keepingCapacity: false)
                }
                Log.info("Call too short (\(Int(dur))s) — discarded from memory; nothing written to disk.")
                return nil
            }
            // Either crossed the threshold or the caller asked us not to
            // discard. Flush now; the flush itself pre-pads the shorter side
            // with silence so me.wav and participants.wav start at the same
            // wall-clock instant.
            bufferQueue.sync { flushBufferToDiskLocked() }
        }

        // All remaining samples are now in the writers. Close (writes WAV
        // headers) is sequenced after the fences so no late append can hit
        // a closed handle.
        bufferQueue.sync {
            micWriter?.close()
            systemWriter?.close()
        }
        let dur = max(systemWriter?.duration ?? 0, micWriter?.duration ?? 0)
        guard let dir = sessionDir,
              let mic = micWriter?.url,
              let sys = systemWriter?.url else { return nil }
        return Result(sessionDir: dir, micWav: mic, systemWav: sys, duration: dur)
    }

    /// Brings the capture stream down, atomically with respect to start().
    private func tearDownCapture() async {
        enum Teardown { case done, park, stop(SCStream?) }
        while true {
            let action: Teardown = stateLock.withLock {
                switch lifecycle {
                case .idle:
                    // start() was never called — nothing to tear down.
                    lifecycle = .stopped
                    return .done
                case .starting:
                    stopRequestedDuringStart = true
                    return .park
                case .running:
                    let s = stream
                    stream = nil
                    lifecycle = .stopping
                    return .stop(s)
                case .stopping, .stopped:
                    // Teardown already done (or owned elsewhere) —
                    // finalization in stop() is idempotent.
                    return .done
                }
            }
            switch action {
            case .done:
                return
            case .park:
                // start() is mid-flight and owns the stream; it sees the flag
                // set above (under the same lock) right after startCapture
                // settles and tears the stream down itself. Park until then,
                // and loop to observe the final state. Registration re-checks
                // the lifecycle so a start() that settled between the two
                // locked regions cannot strand the continuation.
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    let parked = stateLock.withLock { () -> Bool in
                        guard lifecycle == .starting else { return false }
                        startWaiters.append(cont)
                        return true
                    }
                    if !parked { cont.resume() }
                }
            case .stop(let s):
                // stopCapture throws if the stream already died (bug-2 path);
                // that is fine — the queues still drain and the WAVs close.
                stopMicWatchdog()
                if let s { try? await s.stopCapture() }
                stopMicCapture()
                stateLock.withLock { lifecycle = .stopped }
                return
            }
        }
    }

    /// Fires `onFatalError` at most once, and only while the recorder
    /// believes it is running — never during/after a normal stop(). Invoked
    /// off-queue so the engine's handler can call stop() (which fences on
    /// our serial queues) without deadlocking.
    private func fireFatalError() {
        let callback: (() -> Void)? = stateLock.withLock {
            guard !fatalErrorFired, lifecycle == .running else { return nil }
            fatalErrorFired = true
            return onFatalError
        }
        guard let callback else { return }
        DispatchQueue.global(qos: .userInitiated).async { callback() }
    }

    // MARK: SCStreamOutput

    // Consecutive conversion failures per track. Each counter is confined to
    // its track's SCK sample-handler queue (audioQueue / micQueue), so no
    // lock is needed. A single failed buffer is routine (odd format mid
    // device change); a long unbroken run means the track is silently
    // recording nothing — warn early, and treat a sustained run as the same
    // kind of fatality as an unwritable WAV so the engine finalizes the call
    // instead of producing a normal-looking note with a silent track.
    private var systemConvertFailures = 0
    private var micConvertFailures = 0
    /// ~1 s of continuously failing buffers at SCK's ~21 ms cadence.
    private let convertFailureWarnThreshold = 50
    /// ~10 s — the track is dead; fire onFatalError.
    private let convertFailureFatalThreshold = 500

    private func trackConversion(ok: Bool, failures: inout Int, track: String) {
        guard !ok else { failures = 0; return }
        failures += 1
        if failures == convertFailureWarnThreshold {
            Log.warn("'\(track)' track: audio conversion failing continuously — the track is currently recording silence.")
        } else if failures == convertFailureFatalThreshold {
            Log.error("'\(track)' track: audio conversion failed for ~10 s straight — treating the capture as dead.")
            fireFatalError()
        }
    }

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .audio:
            let s = systemConverter.samples(from: sampleBuffer)
            trackConversion(ok: s != nil, failures: &systemConvertFailures, track: "participants")
            if let s {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                ingestSystem(s, pts: pts.isNumeric ? pts.seconds : nil)
            }
        case .microphone:
            let s = micConverter.samples(from: sampleBuffer)
            trackConversion(ok: s != nil, failures: &micConvertFailures, track: "me")
            if let s {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                ingestMic(s, pts: pts.isNumeric ? pts.seconds : nil)
            }
        case .screen:
            break // intentionally ignored
        @unknown default:
            break
        }
    }

    // MARK: - Buffering + flush

    private func ingestMic(_ samples: [Int16], pts: Double?) {
        noteSignal(samples, mic: true)
        bufferQueue.async { [self] in
            if let pad = realignmentPaddingLocked(anchor: &micAnchor, pts: pts, track: "me") {
                appendMicLocked(pad)
            }
            appendMicLocked(samples)
        }
    }

    private func ingestSystem(_ samples: [Int16], pts: Double?) {
        noteSignal(samples, mic: false)
        bufferQueue.async { [self] in
            if let pad = realignmentPaddingLocked(anchor: &systemAnchor, pts: pts, track: "participants") {
                appendSystemLocked(pad)
            }
            appendSystemLocked(samples)
        }
    }

    /// If the track's accumulated sample count lags the PTS-derived position
    /// by more than ~100 ms (dropped buffers, converter failure), returns the
    /// silence needed to re-align. Leads are never trimmed — small ones are
    /// normal clock jitter and dropping audio is worse than any drift.
    private func realignmentPaddingLocked(anchor: inout TrackAnchor,
                                          pts: Double?,
                                          track: String) -> [Int16]? {
        guard let pts else { return nil }
        guard let first = anchor.firstPTS else {
            anchor.firstPTS = pts
            return nil
        }
        let expected = Int(((pts - first) * Double(outputSampleRate)).rounded())
        let lag = expected - anchor.samples
        guard lag > maxLagSamples else { return nil }
        Log.warn("'\(track)' track fell \(String(format: "%.2f", Double(lag) / Double(outputSampleRate)))s behind its capture clock (dropped buffers or conversion failure) — inserting silence to re-align.")
        return [Int16](repeating: 0, count: lag)
    }

    private func appendMicLocked(_ samples: [Int16]) {
        micAnchor.samples += samples.count
        if flushedToDisk {
            if micWriter?.append(samples) == false { fireFatalError() }
            return
        }
        bufferedMicSamples.append(samples)
        bufferedMicFrames += samples.count
        maybeFlushLocked()
    }

    private func appendSystemLocked(_ samples: [Int16]) {
        systemAnchor.samples += samples.count
        if flushedToDisk {
            if systemWriter?.append(samples) == false { fireFatalError() }
            return
        }
        bufferedSystemSamples.append(samples)
        bufferedSystemFrames += samples.count
        maybeFlushLocked()
    }

    private func maybeFlushLocked() {
        let micDur = Double(bufferedMicFrames) / Double(outputSampleRate)
        let sysDur = Double(bufferedSystemFrames) / Double(outputSampleRate)
        if max(micDur, sysDur) >= bufferCapSeconds {
            flushBufferToDiskLocked()
        }
    }

    private func flushBufferToDiskLocked() {
        guard !flushedToDisk else { return }
        flushedToDisk = true
        guard let dir = sessionDir else {
            Log.error("No session directory at flush time — discarding buffered audio.")
            fireFatalError()
            return
        }
        do {
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
        } catch {
            Log.error("Could not create session dir at flush time: \(error.localizedDescription)")
            fireFatalError()
            return
        }
        micWriter = WavWriter(url: dir.appendingPathComponent("me.wav"))
        systemWriter = WavWriter(url: dir.appendingPathComponent("participants.wav"))
        guard micWriter != nil, systemWriter != nil else {
            Log.error("Could not open WAV files for writing — the recording cannot be persisted.")
            fireFatalError()
            return
        }

        // me.wav and participants.wav must start at the same wall-clock
        // instant: Pipeline merges by per-file `startMs` with no offset
        // table, so any frame-count imbalance at flush time becomes a
        // speaker-turn-ordering bug in the transcript. Pre-pad the shorter
        // side with silence so both writers have the same frame count
        // immediately after flush. (This pad represents time before the
        // track's PTS anchor, so it deliberately bypasses the anchor
        // accounting in appendMic/SystemLocked.)
        let micFrames = bufferedMicFrames
        let sysFrames = bufferedSystemFrames
        let diff = abs(micFrames - sysFrames)
        if diff > 0 {
            let silenceSeconds = Double(diff) / Double(outputSampleRate)
            // Probing the voice-processed path holds the "Me" track back by a
            // known amount before falling back to the raw tap. That head is a
            // decision, not a symptom, so it does not count as desync.
            if silenceSeconds - micProbeDelaySeconds > 1.0 {
                Log.warn("Track desync at flush: |me - participants| = \(String(format: "%.2f", silenceSeconds))s. Silence-padding the shorter side; investigate if this recurs.")
            }
            let silence = [Int16](repeating: 0, count: diff)
            if micFrames < sysFrames {
                micWriter?.append(silence)
            } else {
                systemWriter?.append(silence)
            }
        }
        for chunk in bufferedMicSamples { micWriter?.append(chunk) }
        for chunk in bufferedSystemSamples { systemWriter?.append(chunk) }
        bufferedMicSamples.removeAll(keepingCapacity: false)
        bufferedSystemSamples.removeAll(keepingCapacity: false)
        if micWriter?.failed == true || systemWriter?.failed == true {
            fireFatalError()
        }
        Log.info("Recording crossed buffer cap (\(Int(bufferCapSeconds))s) — flushed to disk and now streaming.")
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Capture stopped unexpectedly: \(error.localizedDescription)")
        // Display sleep, permission revocation, SCK failure mid-call: without
        // this the engine shows "Recording…" forever with no audio arriving.
        fireFatalError()
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}
