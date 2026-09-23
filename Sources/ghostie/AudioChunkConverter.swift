import Foundation
import AVFoundation
import CoreMedia

/// Converts ScreenCaptureKit audio sample buffers (typically 48 kHz, stereo,
/// non-interleaved Float32) into the 16 kHz mono Int16 stream whisper.cpp wants.
///
/// Channels are averaged here, by hand; `AVAudioConverter` only changes rate
/// and sample format. Asked to go stereo → mono itself it keeps channel 0 and
/// drops the rest (`downmix` defaults to false) — so on Teams' spatial audio
/// or a panned Zoom call a right-panned speaker came out quieter or missing
/// from participants.wav. Same rule as `MicCapture` and `RecordingImporter`:
/// never ask the converter to change channel count.
final class AudioChunkConverter {
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
    /// Reused mono staging buffer for the fold.
    private var monoBuffer: AVAudioPCMBuffer?
    private let outFormat = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: 16000,
        channels: 1,
        interleaved: true
    )!

    /// Returns 16 kHz mono Int16 samples for one sample buffer, or nil on failure.
    func samples(from sampleBuffer: CMSampleBuffer) -> [Int16]? {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return nil }
        var asbd = asbdPtr.pointee

        guard let input = AVAudioFormat(streamDescription: &asbd) else { return nil }

        let channels = Int(asbd.mChannelsPerFrame)
        let nonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0
        let numBuffers = nonInterleaved ? max(channels, 1) : 1

        let ablPtr = AudioBufferList.allocate(maximumBuffers: numBuffers)
        defer { free(ablPtr.unsafeMutablePointer) }

        var blockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: ablPtr.unsafeMutablePointer,
            bufferListSize: AudioBufferList.sizeInBytes(maximumBuffers: numBuffers),
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, blockBuffer != nil else { return nil }

        guard let pcmIn = AVAudioPCMBuffer(pcmFormat: input,
                                           bufferListNoCopy: ablPtr.unsafePointer) else {
            return nil
        }

        return convert(pcmIn, asbd: asbd)
    }

    /// Everything after the CMSampleBuffer unwrap; internal for the selftest.
    func convert(_ pcmIn: AVAudioPCMBuffer, asbd: AudioStreamBasicDescription) -> [Int16]? {
        let input = pcmIn.format
        let source = input.channelCount > 1 ? (foldToMono(pcmIn) ?? pcmIn) : pcmIn
        if needsNewConverter(for: asbd) || converter?.inputFormat != source.format {
            converter = AVAudioConverter(from: source.format, to: outFormat)
            inFormat = input
        }
        guard let converter else { return nil }

        let ratio = outFormat.sampleRate / input.sampleRate
        let outCapacity = AVAudioFrameCount(Double(source.frameLength) * ratio) + 2048
        guard let pcmOut = AVAudioPCMBuffer(pcmFormat: outFormat,
                                            frameCapacity: outCapacity) else { return nil }

        var fed = false
        var convError: NSError?
        let result = converter.convert(to: pcmOut, error: &convError) { _, statusPtr in
            if fed {
                statusPtr.pointee = .noDataNow
                return nil
            }
            fed = true
            statusPtr.pointee = .haveData
            return source
        }

        guard result != .error, pcmOut.frameLength > 0,
              let channelData = pcmOut.int16ChannelData else { return nil }

        let count = Int(pcmOut.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
    }

    /// Average every channel of a Float32 buffer (interleaved or not) into a
    /// mono Float32 buffer at the same rate. Nil for any other sample format,
    /// which then goes to the converter as before rather than being guessed at.
    private func foldToMono(_ input: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard input.format.commonFormat == .pcmFormatFloat32,
              let src = input.floatChannelData else { return nil }
        let frames = Int(input.frameLength)
        let channels = Int(input.format.channelCount)
        if monoBuffer == nil
            || monoBuffer!.format.sampleRate != input.format.sampleRate
            || monoBuffer!.frameCapacity < input.frameLength {
            guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                          sampleRate: input.format.sampleRate,
                                          channels: 1, interleaved: false) else { return nil }
            monoBuffer = AVAudioPCMBuffer(pcmFormat: fmt,
                                          frameCapacity: max(input.frameLength, 4096))
        }
        guard let mono = monoBuffer, let dst = mono.floatChannelData?[0] else { return nil }
        mono.frameLength = input.frameLength
        let scale = 1 / Float(channels)
        if input.format.isInterleaved {
            let p = src[0]
            for f in 0..<frames {
                var sum: Float = 0
                for c in 0..<channels { sum += p[f * channels + c] }
                dst[f] = sum * scale
            }
        } else {
            for f in 0..<frames { dst[f] = src[0][f] }
            for c in 1..<channels {
                let p = src[c]
                for f in 0..<frames { dst[f] += p[f] }
            }
            for f in 0..<frames { dst[f] *= scale }
        }
        return mono
    }

    /// A device swap can change channel count, sample format, or interleaving
    /// without changing the rate; comparing only the sample rate left the
    /// cached converter failing on every subsequent buffer (audio silently
    /// lost). Compare every relevant field of the incoming ASBD instead.
    private func needsNewConverter(for asbd: AudioStreamBasicDescription) -> Bool {
        guard converter != nil,
              let cached = inFormat?.streamDescription.pointee else { return true }
        return cached.mSampleRate != asbd.mSampleRate
            || cached.mFormatID != asbd.mFormatID
            || cached.mFormatFlags != asbd.mFormatFlags
            || cached.mChannelsPerFrame != asbd.mChannelsPerFrame
            || cached.mBitsPerChannel != asbd.mBitsPerChannel
            || cached.mBytesPerFrame != asbd.mBytesPerFrame
            || cached.mBytesPerPacket != asbd.mBytesPerPacket
            || cached.mFramesPerPacket != asbd.mFramesPerPacket
    }
}
