import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreMedia

/// Records a Teams call entirely locally — no bot joins the meeting.
///
/// ScreenCaptureKit gives us two independent audio taps:
///   • `.audio`      → everything the system plays  = the other participants
///   • `.microphone` → the local microphone          = me
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
            finishStart(as: .stopped)
            throw error
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

        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.sampleRate = 48000
        cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        cfg.captureMicrophone = true            // macOS 15+ : separate mic tap
        // Minimal video — required to keep the stream alive; frames are dropped.
        cfg.width = 2
        cfg.height = 2
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.queueDepth = 6
        cfg.showsCursor = false

        let s = SCStream(filter: filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try s.addStreamOutput(self, type: .microphone, sampleHandlerQueue: micQueue)
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
            finishStart(as: .stopped)
            Log.info("stop() arrived during startup — capture torn down immediately.")
            return
        }
        Log.ok("Recording → \(sessionDir.path)")
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
                if let s { try? await s.stopCapture() }
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

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .audio:
            if let s = systemConverter.samples(from: sampleBuffer) {
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                ingestSystem(s, pts: pts.isNumeric ? pts.seconds : nil)
            }
        case .microphone:
            if let s = micConverter.samples(from: sampleBuffer) {
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
        bufferQueue.async { [self] in
            if let pad = realignmentPaddingLocked(anchor: &micAnchor, pts: pts, track: "me") {
                appendMicLocked(pad)
            }
            appendMicLocked(samples)
        }
    }

    private func ingestSystem(_ samples: [Int16], pts: Double?) {
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
            if silenceSeconds > 1.0 {
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
