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
final class MicCapture {
    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private let onSamples: ([Int16], Double?) -> Void
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                          sampleRate: 16_000,
                                          channels: 1,
                                          interleaved: true)!

    init(onSamples: @escaping ([Int16], Double?) -> Void) {
        self.onSamples = onSamples
    }

    func start() throws {
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
        converter = conv

        input.installTap(onBus: 0, bufferSize: 1024, format: inFormat) {
            [weak self] buffer, when in
            self?.handle(buffer: buffer, when: when)
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    private func handle(buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        guard let converter else { return }
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
        let pts = when.isHostTimeValid
            ? AVAudioTime.seconds(forHostTime: when.hostTime) : nil
        onSamples(samples, pts)
    }
}
