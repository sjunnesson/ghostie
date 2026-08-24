import Foundation
import AVFoundation

/// Echo-cancelled microphone capture.
///
/// ScreenCaptureKit's `.microphone` tap is a *raw* tap: whatever the speakers
/// play — i.e. the other participants — re-enters through the mic, so without
/// headphones the "Me" track duplicates the "Participants" track wholesale.
/// Apple's voice-processing I/O (the FaceTime stack) cancels the *device
/// output* — every app's audio, Teams included — from the mic signal, so this
/// capture path records only the local voice. `EchoSuppressor` stays on as the
/// text-level backstop (Bluetooth latency can defeat AEC).
///
/// Emits 16 kHz mono Int16 chunks plus a host-clock PTS in seconds — the same
/// shape `AudioChunkConverter` produces for the SCK taps — so `AudioRecorder`
/// ingests both mic paths identically. `AudioRecorder` falls back to the raw
/// SCK tap automatically if `start()` throws (no input device, VP refusal).
///
/// ## Surviving device changes
///
/// `AVAudioEngine` **stops itself** when the audio hardware configuration
/// changes — the user picks up AirPods, a call app grabs the default input,
/// a dock is unplugged. It posts `AVAudioEngineConfigurationChange` and the
/// installed tap goes inert: no error, no throw, no callback, and any WAV fed
/// from it silently becomes digital zeros for the rest of the call. That is
/// exactly how the 2026-08-24 recording lost 59 minutes of the local speaker
/// (`detector: audio device topology changed` fired twice within a second of
/// `engine.start()`). So the notification is observed here and the whole
/// voice-processing graph is rebuilt against whatever device is now current.
///
/// Rebuilds are debounced (topology changes arrive in bursts) and capped, and
/// `hasEverHadSignal` lets `AudioRecorder` escalate to the raw SCK tap when
/// even a rebuilt graph produces nothing.
final class MicCapture {

    /// Serializes build/teardown. The audio tap never touches it, so a rebuild
    /// can never block a render callback.
    private let control = DispatchQueue(label: "ghostie.mic.control")
    /// Guards the flags read from outside (`hasEverHadSignal`, `rebuildCount`).
    private let stateLock = NSLock()

    private let onSamples: ([Int16], Double?) -> Void
    /// Fired on `control` after the graph is rebuilt against a new device.
    /// The recorder re-anchors the "Me" track's PTS clock: the new source
    /// starts a fresh timeline and comparing it to the old anchor would
    /// otherwise inject a huge realignment pad.
    var onRebuilt: (() -> Void)?

    private var engine: AVAudioEngine?
    private var observer: NSObjectProtocol?
    private var running = false
    private var rebuildScheduled = false
    private var rebuilds = 0
    private var sawSignal = false
    private var delivered = 0

    /// Configuration changes arrive in bursts during a single device swap;
    /// coalesce them into one rebuild.
    private static let rebuildDebounce: TimeInterval = 0.4
    /// A device that renegotiates forever must not spin the graph forever.
    private static let maxRebuilds = 12

    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16_000,
                                          channels: 1,
                                          interleaved: true)!

    init(onSamples: @escaping ([Int16], Double?) -> Void) {
        self.onSamples = onSamples
    }

    /// True once any non-zero sample has reached the recorder. Digital silence
    /// is the signature of a dead graph — a *live* mic always carries a noise
    /// floor — so this is what the recorder's watchdog tests, rather than a
    /// level threshold that a genuinely quiet user would trip.
    var hasEverHadSignal: Bool { stateLock.withLock { sawSignal } }

    /// How many times the graph has been rebuilt (device swaps + watchdog).
    var rebuildCount: Int { stateLock.withLock { rebuilds } }

    /// Buffers handed to the recorder so far. A dead graph is not a *quiet*
    /// graph — it keeps delivering buffers at the normal cadence, they are
    /// simply empty. So once a handful have arrived carrying nothing, the
    /// verdict is already in and the probe need not wait out its full window.
    var deliveredBuffers: Int { stateLock.withLock { delivered } }

    func start() throws {
        try control.sync {
            guard !running else { return }
            try buildLocked()
            running = true
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.scheduleRebuild(reason: "audio configuration changed (device swap)")
        }
    }

    func stop() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        control.sync {
            running = false
            teardownLocked()
        }
    }

    /// Rebuilds the graph on demand — the recorder's watchdog calls this when
    /// the track has produced nothing but zeros and no configuration-change
    /// notification ever arrived (the swap happened before the engine was
    /// observing, or the driver wedged without announcing it).
    func restart(reason: String) {
        scheduleRebuild(reason: reason, debounce: 0)
    }

    // MARK: - Graph lifecycle (all on `control`)

    private func scheduleRebuild(reason: String, debounce: TimeInterval = rebuildDebounce) {
        control.async { [weak self] in
            guard let self, self.running, !self.rebuildScheduled else { return }
            self.rebuildScheduled = true
            self.control.asyncAfter(deadline: .now() + debounce) {
                self.rebuildScheduled = false
                guard self.running else { return }
                self.rebuildLocked(reason: reason)
            }
        }
    }

    private func rebuildLocked(reason: String) {
        let count = stateLock.withLock { () -> Int in
            rebuilds += 1
            return rebuilds
        }
        guard count <= Self.maxRebuilds else {
            Log.warn("Mic capture: \(reason), but the voice-processing graph has already been rebuilt \(Self.maxRebuilds) times — leaving it alone.")
            return
        }
        Log.info("Mic capture: \(reason) — rebuilding the voice-processing graph (attempt \(count)).")
        stateLock.withLock { delivered = 0 }
        teardownLocked()
        do {
            try buildLocked()
            onRebuilt?()
        } catch {
            Log.warn("Mic capture: rebuild failed (\(error.localizedDescription)) — the 'Me' track stays silent until the recorder falls back to the raw tap.")
        }
    }

    private func buildLocked() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        // Voice processing ducks other apps' audio by default — that would
        // quietly lower the live Teams call for the user. Keep it minimal.
        input.voiceProcessingOtherAudioDuckingConfiguration =
            AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
                enableAdvancedDucking: false, duckingLevel: .min)

        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            throw NSError(domain: "ghostie", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "No usable microphone input format."])
        }
        guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw NSError(domain: "ghostie", code: 3, userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot convert \(Int(inFormat.sampleRate)) Hz mic input to 16 kHz mono."])
        }

        // The converter is captured by the tap rather than stored on `self`:
        // a rebuild's new tap then owns its own converter and can never race
        // an in-flight callback from the graph being torn down.
        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) {
            [weak self] buffer, when in
            self?.handle(buffer: buffer, when: when, converter: conv)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
    }

    private func teardownLocked() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Release the device cleanly so the rebuilt graph (or the SCK raw tap
        // the recorder may fall back to) can claim it.
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        self.engine = nil
    }

    // MARK: - Sample path

    private func handle(buffer: AVAudioPCMBuffer, when: AVAudioTime,
                        converter: AVAudioConverter) {
        let ratio = outFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: outFormat,
                                         frameCapacity: capacity) else { return }
        // One input buffer per convert call; `.noDataNow` (not `.endOfStream`)
        // keeps the converter's resampler state alive across chunks.
        var fed = false
        var convErr: NSError?
        converter.convert(to: out, error: &convErr) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        guard convErr == nil, out.frameLength > 0,
              let ch = out.int16ChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: ch[0],
                                                count: Int(out.frameLength)))
        noteSignal(in: samples)
        stateLock.withLock { delivered += 1 }
        let pts = when.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil
        onSamples(samples, pts)
    }

    /// Latches `sawSignal` on the first non-zero sample. The scan stops
    /// costing anything once the latch is set — the common case is one scan
    /// of the first buffer, since a live mic is never digitally silent.
    private func noteSignal(in samples: [Int16]) {
        guard !hasEverHadSignal else { return }
        guard samples.contains(where: { $0 != 0 }) else { return }
        stateLock.withLock { sawSignal = true }
    }
}
