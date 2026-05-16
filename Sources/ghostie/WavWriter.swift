import Foundation

/// Streams 16-bit PCM samples to a .wav file and patches the RIFF header on close.
/// We always write mono so the file is exactly what whisper.cpp wants (16 kHz mono).
final class WavWriter {
    private let handle: FileHandle
    private let sampleRate: Int
    private let channels: Int
    private var dataBytes: UInt32 = 0
    private(set) var totalFrames: Int = 0
    let url: URL

    init?(url: URL, sampleRate: Int = 16000, channels: Int = 1) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = h
        writeHeaderPlaceholder()
    }

    private func writeHeaderPlaceholder() {
        // 44-byte canonical PCM WAV header, sizes filled in on close().
        var header = Data(count: 44)
        header.replaceSubrange(0..<4, with: Array("RIFF".utf8))
        header.replaceSubrange(8..<12, with: Array("WAVE".utf8))
        header.replaceSubrange(12..<16, with: Array("fmt ".utf8))
        write(&header, 16, UInt32(16))                  // fmt chunk size
        write(&header, 20, UInt16(1))                   // PCM
        write(&header, 22, UInt16(channels))
        write(&header, 24, UInt32(sampleRate))
        let byteRate = UInt32(sampleRate * channels * 2)
        write(&header, 28, byteRate)
        write(&header, 32, UInt16(channels * 2))        // block align
        write(&header, 34, UInt16(16))                  // bits per sample
        header.replaceSubrange(36..<40, with: Array("data".utf8))
        handle.write(header)
    }

    func append(_ samples: [Int16]) {
        guard !samples.isEmpty else { return }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        handle.write(data)
        dataBytes += UInt32(data.count)
        totalFrames += samples.count / channels
    }

    /// Seconds of audio written so far.
    var duration: Double { Double(totalFrames) / Double(sampleRate) }

    func close() {
        var sizes = Data(count: 8)
        write(&sizes, 0, UInt32(36) + dataBytes)        // RIFF chunk size
        write(&sizes, 4, dataBytes)                     // data chunk size
        try? handle.seek(toOffset: 4)
        handle.write(sizes.subdata(in: 0..<4))
        try? handle.seek(toOffset: 40)
        handle.write(sizes.subdata(in: 4..<8))
        try? handle.close()
    }

    private func write(_ d: inout Data, _ offset: Int, _ value: UInt32) {
        var v = value.littleEndian
        d.replaceSubrange(offset..<offset+4, with: Swift.withUnsafeBytes(of: &v) { Array($0) })
    }
    private func write(_ d: inout Data, _ offset: Int, _ value: UInt16) {
        var v = value.littleEndian
        d.replaceSubrange(offset..<offset+2, with: Swift.withUnsafeBytes(of: &v) { Array($0) })
    }
}
