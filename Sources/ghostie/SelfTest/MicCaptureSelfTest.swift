import Foundation
import AVFoundation

/// Regression check for the microphone conversion path.
///
/// This exists because of a bug that survived two releases while looking like
/// an operating-system fault. Enabling voice processing turns the input node
/// into a 9-channel stream; `AVAudioConverter` asked to fold that to 1 channel
/// returns success, fills the output buffer to the expected length, and writes
/// nothing but zeros. Downstream that is indistinguishable from a dead
/// microphone, so it was diagnosed as "voice processing is broken on macOS 26"
/// and worked around by falling back to the raw tap — which is what put the
/// other participants' voices onto the local speaker's track.
///
/// `monoise` is the fix: take channel 0 ourselves and leave the converter only
/// a sample-rate and sample-format change. These checks are pure buffer
/// arithmetic — no device, no permission, no audio.
func runMicCaptureSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)  \(detail())") }
    }

    /// A deinterleaved float buffer where channel `c` holds `value(c, frame)`.
    ///
    /// Built through an explicit discrete channel layout, because
    /// `AVAudioFormat(standardFormatWithSampleRate:channels:)` returns nil
    /// above two channels — there is no standard layout for nine, which is
    /// part of why this stream is awkward in the first place.
    func makeBuffer(channels: AVAudioChannelCount, frames: AVAudioFrameCount,
                    sampleRate: Double = 48_000,
                    value: (Int, Int) -> Float) -> AVAudioPCMBuffer? {
        let fmt: AVAudioFormat?
        if channels <= 2 {
            fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
        } else {
            let tag = kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channels)
            guard let layout = AVAudioChannelLayout(layoutTag: tag) else { return nil }
            fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                interleaved: false, channelLayout: layout)
        }
        guard let fmt, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: max(1, frames))
        else { return nil }
        buf.frameLength = frames
        for c in 0..<Int(channels) {
            for f in 0..<Int(frames) { buf.floatChannelData![c][f] = value(c, f) }
        }
        return buf
    }

    // The shape voice processing actually produced on macOS 26.5: 9 channels,
    // the voice on channel 0, the rest of the array carrying something else.
    guard let nine = makeBuffer(channels: 9, frames: 512, value: { c, f in
        c == 0 ? Float(f % 100) / 100 : -1
    }) else {
        print("  ✗ could not build a 9-channel fixture")
        print("mic-capture self-test: 0 passed, 1 failed")
        return false
    }
    let mono = MicCapture.monoise(nine)
    check("a 9-channel buffer reduces to 1 channel",
          mono?.format.channelCount == 1, "got \(String(describing: mono?.format.channelCount))")
    check("frame count and sample rate survive the reduction",
          mono?.frameLength == 512 && mono?.format.sampleRate == 48_000)
    check("it carries channel 0, not a fold of every channel",
          {
              guard let d = mono?.floatChannelData else { return false }
              return (0..<512).allSatisfy { abs(d[0][$0] - Float($0 % 100) / 100) < 1e-6 }
          }(),
          "channel 0 was not copied through verbatim")
    check("the signal is not silenced — the failure this guards against",
          {
              guard let d = mono?.floatChannelData else { return false }
              return (0..<512).contains { d[0][$0] != 0 }
          }())

    // Already mono: handed straight back, no copy, no format change.
    let one = makeBuffer(channels: 1, frames: 256) { _, f in Float(f) / 256 }
    check("a mono buffer is passed through untouched",
          one != nil && MicCapture.monoise(one!) === one!)

    // Stereo is the other common shape; channel 0 is still the rule.
    let stereo = makeBuffer(channels: 2, frames: 128) { c, _ in c == 0 ? 0.5 : -0.5 }
    let stereoMono = stereo.flatMap { MicCapture.monoise($0) }
    check("stereo takes channel 0 rather than averaging to zero",
          {
              // `stereoMono` is bound to a local on purpose: floatChannelData
              // points into the buffer, and reading it off a temporary leaves
              // a dangling pointer the moment ARC releases it.
              guard let d = stereoMono?.floatChannelData else { return false }
              return (0..<128).allSatisfy { abs(d[0][$0] - 0.5) < 1e-6 }
          }())

    // A rate other than 48 kHz must survive: the converter is built from the
    // device's rate, so a mismatch here would silently resample wrongly.
    let at16k = makeBuffer(channels: 4, frames: 64, sampleRate: 16_000) { c, _ in
        c == 0 ? 0.25 : 0
    }
    check("the source sample rate is preserved, not normalised",
          at16k != nil && MicCapture.monoise(at16k!)?.format.sampleRate == 16_000)

    // An empty buffer must be skipped, not reduced: AVAudioPCMBuffer raises
    // on a zero frame capacity, so this crashed the process before the guard.
    let empty = makeBuffer(channels: 9, frames: 0) { _, _ in 0 }
    check("a zero-length buffer is skipped rather than trapping",
          empty != nil && MicCapture.monoise(empty!) == nil)

    // Reading a nominated channel, and finding a live one when the nominated
    // channel dies — the recovery path for a future macOS renumbering the
    // voice-processing layout, as macOS 26 already renumbered it once.
    guard let ch3 = makeBuffer(channels: 9, frames: 64, value: { c, _ in
        c == 3 ? 0.75 : 0
    }) else {
        check("could not build a channel-3 fixture", false); 
        print("mic-capture self-test: \(passed) passed, \(failed) failed")
        return false
    }
    let fromCh3 = MicCapture.monoise(ch3, channel: 3)
    check("monoise reads the channel it is told to",
          {
              guard let d = fromCh3?.floatChannelData else { return false }
              return (0..<64).allSatisfy { abs(d[0][$0] - 0.75) < 1e-6 }
          }())
    let fromCh0 = MicCapture.monoise(ch3, channel: 0)
    check("the default channel really is 0 (silent in this fixture)",
          {
              guard let d = fromCh0?.floatChannelData else { return false }
              return (0..<64).allSatisfy { d[0][$0] == 0 }
          }())
    check("an out-of-range channel is clamped, not read past the end",
          MicCapture.monoise(ch3, channel: 99)?.frameLength == 64)

    check("firstChannelWithSignal finds the live channel",
          MicCapture.firstChannelWithSignal(ch3) == 3)
    check("firstChannelWithSignal prefers the lowest live channel",
          {
              guard let b = makeBuffer(channels: 9, frames: 32, value: { c, _ in
                  c == 2 || c == 5 ? 0.5 : 0
              }) else { return false }
              return MicCapture.firstChannelWithSignal(b) == 2
          }())
    check("a wholly silent buffer nominates no channel — a quiet room never switches",
          {
              guard let b = makeBuffer(channels: 9, frames: 32, value: { _, _ in 0 })
              else { return false }
              return MicCapture.firstChannelWithSignal(b) == nil
          }())

    print("mic-capture self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
