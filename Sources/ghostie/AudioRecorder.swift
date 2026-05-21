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
final class AudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

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

    init(config: Config) {
        self.config = config
    }

    /// Requests permissions and starts capture. Throws if it cannot start.
    func start() async throws {
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
        stream = s
        Log.ok("Recording → \(sessionDir.path)")
    }

    /// Stops capture, finalizes the WAV files and returns their locations.
    /// Returns nil if the recording was shorter than `config.minCallSeconds`
    /// and the buffer never flushed to disk (the in-memory PCM is dropped
    /// and the session dir, if any, is removed). Replaces the post-hoc
    /// Engine-side `minCallSeconds` discard.
    func stop() async -> Result? {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
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
            if dur < config.minCallSeconds {
                bufferQueue.sync {
                    bufferedMicSamples.removeAll(keepingCapacity: false)
                    bufferedSystemSamples.removeAll(keepingCapacity: false)
                }
                Log.info("Call too short (\(Int(dur))s) — discarded from memory; nothing written to disk.")
                return nil
            }
            // Crossed the threshold: flush now. The flush itself pre-pads
            // the shorter side with silence so me.wav and participants.wav
            // start at the same wall-clock instant.
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

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        switch type {
        case .audio:
            if let s = systemConverter.samples(from: sampleBuffer) {
                ingestSystem(s)
            }
        case .microphone:
            if let s = micConverter.samples(from: sampleBuffer) {
                ingestMic(s)
            }
        case .screen:
            break // intentionally ignored
        @unknown default:
            break
        }
    }

    // MARK: - Buffering + flush

    private func ingestMic(_ samples: [Int16]) {
        bufferQueue.async { [self] in
            if flushedToDisk {
                micWriter?.append(samples)
                return
            }
            bufferedMicSamples.append(samples)
            bufferedMicFrames += samples.count
            maybeFlushLocked()
        }
    }

    private func ingestSystem(_ samples: [Int16]) {
        bufferQueue.async { [self] in
            if flushedToDisk {
                systemWriter?.append(samples)
                return
            }
            bufferedSystemSamples.append(samples)
            bufferedSystemFrames += samples.count
            maybeFlushLocked()
        }
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
        do {
            try FileManager.default.createDirectory(
                at: sessionDir, withIntermediateDirectories: true)
        } catch {
            Log.error("Could not create session dir at flush time: \(error.localizedDescription)")
            return
        }
        micWriter = WavWriter(url: sessionDir.appendingPathComponent("me.wav"))
        systemWriter = WavWriter(url: sessionDir.appendingPathComponent("participants.wav"))

        // me.wav and participants.wav must start at the same wall-clock
        // instant: Pipeline merges by per-file `startMs` with no offset
        // table, so any frame-count imbalance at flush time becomes a
        // speaker-turn-ordering bug in the transcript. Pre-pad the shorter
        // side with silence so both writers have the same frame count
        // immediately after flush.
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
        Log.info("Recording crossed buffer cap (\(Int(bufferCapSeconds))s) — flushed to disk and now streaming.")
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.error("Capture stopped unexpectedly: \(error.localizedDescription)")
    }

    static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}
