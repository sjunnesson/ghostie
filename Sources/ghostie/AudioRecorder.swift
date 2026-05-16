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
    private(set) var startedAt = Date()

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
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        micWriter = WavWriter(url: sessionDir.appendingPathComponent("me.wav"))
        systemWriter = WavWriter(url: sessionDir.appendingPathComponent("participants.wav"))

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
    func stop() async -> Result? {
        if let s = stream { try? await s.stopCapture() }
        stream = nil
        micWriter?.close()
        systemWriter?.close()
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
                systemWriter?.append(s)
            }
        case .microphone:
            if let s = micConverter.samples(from: sampleBuffer) {
                micWriter?.append(s)
            }
        case .screen:
            break // intentionally ignored
        @unknown default:
            break
        }
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
