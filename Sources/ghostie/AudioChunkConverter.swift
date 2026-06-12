import Foundation
import AVFoundation
import CoreMedia

/// Converts ScreenCaptureKit audio sample buffers (typically 48 kHz, stereo,
/// non-interleaved Float32) into the 16 kHz mono Int16 stream whisper.cpp wants.
final class AudioChunkConverter {
    private var converter: AVAudioConverter?
    private var inFormat: AVAudioFormat?
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

        if needsNewConverter(for: asbd) {
            converter = AVAudioConverter(from: input, to: outFormat)
            inFormat = input
        }
        guard let converter else { return nil }

        let ratio = outFormat.sampleRate / input.sampleRate
        let outCapacity = AVAudioFrameCount(Double(pcmIn.frameLength) * ratio) + 2048
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
            return pcmIn
        }

        guard result != .error, pcmOut.frameLength > 0,
              let channelData = pcmOut.int16ChannelData else { return nil }

        let count = Int(pcmOut.frameLength)
        return Array(UnsafeBufferPointer(start: channelData[0], count: count))
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
