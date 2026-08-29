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
    private var lostInConversion = 0
    /// Which input channel carries the processed voice. Channel 0 today; see
    /// `adaptChannelIfDead`.
    private var activeChannel = 0
    private var deadChannelBuffers = 0

    /// Configuration changes arrive in bursts during a single device swap;
    /// coalesce them into one rebuild.
    private static let rebuildDebounce: TimeInterval = 0.4
    /// A device that renegotiates forever must not spin the graph forever.
    private static let maxRebuilds = 12
    /// Converted-to-silence buffers tolerated before saying so. The converter
    /// legitimately yields nothing while priming.
    private static let conversionLossAlarm = 5
    /// Consecutive buffers where the chosen channel is silent and another is
    /// not, before switching. Long enough that a pause in speech cannot move
    /// us; short enough to recover within a second.
    private static let deadChannelGrace = 25

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

    /// Buffers that arrived from the device carrying sound and left the
    /// converter carrying none. Distinguishes "the microphone gave us
    /// nothing" from "we destroyed what it gave us" — which are identical
    /// downstream and were confused for each other for two releases.
    var buffersLostInConversion: Int { stateLock.withLock { lostInConversion } }

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
        // Reduce to mono ourselves and hand AVAudioConverter only a sample-rate
        // and sample-format change.
        //
        // Voice processing does not hand back the tidy 1-channel stream you
        // might expect: on this Mac (macOS 26.5) enabling it turns the input
        // node into **9 ch, 48 kHz, Float32, deinterleaved**. Asked to fold
        // that to 1 ch, AVAudioConverter returns `noErr`, fills the output
        // buffer to the expected length, and writes **all zeros** — measured
        // 131037/139200 non-zero samples going in, 0/46357 coming out. That is
        // the whole "voice processing is dead on macOS 26" story: the unit was
        // working the entire time and this converter was discarding it, which
        // then tripped the silence watchdog and dropped the call onto the raw
        // tap, where the Me track picks up the speakers (2026-08-28: 41% of it
        // duplicated Participants).
        //
        // Channel *count* conversion is the fragile part, so it is no longer
        // asked for. `monoise` copies channel 0 — under voice processing that
        // is the processed voice; the other channels are array elements and
        // averaging them back in would undo the echo cancellation.
        let monoFormat = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate,
                                       channels: 1)
        guard let monoFormat, let conv = AVAudioConverter(from: monoFormat, to: outFormat) else {
            throw NSError(domain: "ghostie", code: 3, userInfo: [
                NSLocalizedDescriptionKey:
                    "Cannot convert \(Int(inFormat.sampleRate)) Hz mic input to 16 kHz mono."])
        }
        if inFormat.channelCount != 1 {
            Log.info("Mic capture: input is \(inFormat.channelCount)ch @ \(Int(inFormat.sampleRate)) Hz — taking channel 0.")
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

    /// Channel 0 as a 1-channel buffer at the source rate, or the buffer
    /// itself when it is already mono. nil for a non-float tap format, which
    /// AVAudioEngine does not produce in practice — the caller then skips the
    /// buffer rather than guessing at its memory layout.
    private static let unsupportedFormatLock = NSLock()
    private nonisolated(unsafe) static var warnedUnsupportedFormat = false
    private static func warnUnsupportedFormatOnce(_ format: AVAudioFormat) {
        let first = unsupportedFormatLock.withLock { () -> Bool in
            if warnedUnsupportedFormat { return false }
            warnedUnsupportedFormat = true
            return true
        }
        guard first else { return }
        Log.warn("Mic capture: the microphone tap delivered \(format) — not the float format this build knows how to reduce to mono. Falling back to the raw tap.")
    }

    /// The lowest channel carrying a non-zero sample, or nil if the buffer is
    /// silent everywhere. Used to recover when the channel we were reading
    /// goes dead — see `activeChannel`. Static + pure for the self-test.
    static func firstChannelWithSignal(_ buffer: AVAudioPCMBuffer) -> Int? {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return nil }
        for c in 0..<Int(buffer.format.channelCount) {
            for f in 0..<Int(buffer.frameLength) where data[c][f] != 0 { return c }
        }
        return nil
    }

    static func monoise(_ buffer: AVAudioPCMBuffer, channel: Int = 0) -> AVAudioPCMBuffer? {
        if buffer.format.channelCount == 1 { return buffer }
        // AVAudioPCMBuffer raises on a zero frame capacity, and an empty
        // buffer has nothing to reduce — skip it rather than trap.
        guard buffer.frameLength > 0 else { return nil }
        guard let src = buffer.floatChannelData else {
            // AVAudioEngine taps are Float32 by contract; if that ever stops
            // being true, say so rather than dropping every buffer in
            // silence and leaving the next person to rediscover this the
            // hard way. The recorder's watchdog still falls back to the raw
            // tap, so the call is recorded either way.
            warnUnsupportedFormatOnce(buffer.format)
            return nil
        }
        guard
              let monoFormat = AVAudioFormat(standardFormatWithSampleRate:
                                                buffer.format.sampleRate, channels: 1),
              let mono = AVAudioPCMBuffer(pcmFormat: monoFormat,
                                          frameCapacity: buffer.frameLength),
              let dst = mono.floatChannelData else { return nil }
        let ch = min(max(0, channel), Int(buffer.format.channelCount) - 1)
        mono.frameLength = buffer.frameLength
        dst[0].update(from: src[ch], count: Int(buffer.frameLength))
        return mono
    }

    private func handle(buffer rawBuffer: AVAudioPCMBuffer, when: AVAudioTime,
                        converter: AVAudioConverter) {
        adaptChannelIfDead(rawBuffer)
        let channel = stateLock.withLock { activeChannel }
        guard let buffer = Self.monoise(rawBuffer, channel: channel) else { return }
        // Did the device give us anything? Compared against the conversion
        // result below, this is what tells a silent microphone apart from a
        // conversion that ate the signal.
        var inputHadSignal = false
        if let f = buffer.floatChannelData {
            for i in 0..<Int(buffer.frameLength) where f[0][i] != 0 {
                inputHadSignal = true; break
            }
        }
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
        if inputHadSignal, !samples.contains(where: { $0 != 0 }) {
            let n = stateLock.withLock { () -> Int in
                lostInConversion += 1
                return lostInConversion
            }
            // The converter primes on its first buffer or two, so a single
            // empty result at start-up is normal. A *run* of them is the
            // failure this counter exists to name.
            if n == Self.conversionLossAlarm {
                Log.warn("Mic capture: the device delivered audio but the 16 kHz conversion produced silence \(n) times — the 'Me' track is being lost in conversion, not at the microphone.")
            }
        }
        noteSignal(in: samples)
        stateLock.withLock { delivered += 1 }
        let pts = when.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil
        onSamples(samples, pts)
    }

    /// Move off a channel that has gone silent while another still carries
    /// sound.
    ///
    /// Voice processing has already changed shape underneath this code once —
    /// what used to be a plain mono input is nine channels on macOS 26, with
    /// the processed voice on channel 0. If a future release renumbers them,
    /// hardcoding channel 0 would hand back digital silence and the whole call
    /// would drop to the raw tap and pick up the speakers. So: only when the
    /// selected channel has been dead for a while *and* another channel is
    /// demonstrably live do we move — a quiet speaker never trips it, because
    /// then no channel has signal either.
    private func adaptChannelIfDead(_ buffer: AVAudioPCMBuffer) {
        guard !hasEverHadSignal, buffer.format.channelCount > 1 else { return }
        let current = stateLock.withLock { activeChannel }
        if let live = Self.firstChannelWithSignal(buffer), live != current {
            let n = stateLock.withLock { () -> Int in
                deadChannelBuffers += 1
                return deadChannelBuffers
            }
            guard n >= Self.deadChannelGrace else { return }
            stateLock.withLock { activeChannel = live; deadChannelBuffers = 0 }
            Log.warn("Mic capture: channel \(current) delivered only silence; channel \(live) is carrying audio — reading that instead.")
        } else {
            stateLock.withLock { deadChannelBuffers = 0 }
        }
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
