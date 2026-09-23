import Foundation

/// Streams 16-bit PCM samples to a .wav file, keeping the RIFF header current
/// (every ~10 s of audio, and on close).
/// We always write mono so the file is exactly what whisper.cpp wants (16 kHz mono).
///
/// Writes use the throwing `FileHandle.write(contentsOf:)` — the legacy
/// `write(_:)` raises an ObjC exception Swift cannot catch, so a full disk
/// used to take down the whole app mid-call. The first failed write poisons
/// the writer (logged once, further appends dropped) and is surfaced via
/// `failed` so the recorder can treat the track as a dead recording; close()
/// still patches a valid header for whatever *was* written, because the size
/// counters only advance on successful writes.
final class WavWriter {
    private let handle: FileHandle
    private let sampleRate: Int
    private let channels: Int
    private var dataBytes: UInt32 = 0
    /// `dataBytes` at the last header patch; see `patchInterval`.
    private var patchedBytes: UInt32 = 0
    private var closed = false
    private(set) var totalFrames: Int = 0
    /// True once a write has failed (disk full, volume gone). Sticky: no
    /// further sample data is accepted, but close() still finalizes the header.
    private(set) var failed = false
    let url: URL

    init?(url: URL, sampleRate: Int = 16000, channels: Int = 1) {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return nil }
        self.handle = h
        do {
            try writeHeaderPlaceholder()
        } catch {
            Log.error("Could not write WAV header for \(url.lastPathComponent): \(error.localizedDescription)")
            try? h.close()
            return nil
        }
    }

    private func writeHeaderPlaceholder() throws {
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
        try handle.write(contentsOf: header)
    }

    /// Appends samples. Returns false if this writer is poisoned (a previous
    /// or the current write failed) — the caller should treat the track as a
    /// dead recording.
    @discardableResult
    func append(_ samples: [Int16]) -> Bool {
        guard !failed, !closed else { return false }
        guard !samples.isEmpty else { return true }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        do {
            try handle.write(contentsOf: data)
        } catch {
            failed = true
            Log.error("Could not write to \(url.lastPathComponent) (disk full?): \(error.localizedDescription) — dropping further audio for this file.")
            return false
        }
        dataBytes += UInt32(data.count)
        totalFrames += samples.count / channels
        if dataBytes - patchedBytes >= patchInterval {
            // Keep the header current while recording, so a file cut off by
            // a crash or kill is still a valid WAV holding everything up to
            // the last patch — not a header claiming 0 bytes, which
            // whisper-cli decodes as empty. A failure poisons the writer like
            // any failed write: after a failed seek the file offset is unknown,
            // and appending anyway could write audio over the header.
            if (try? patchHeader()) != nil, (try? handle.seekToEnd()) != nil {
                patchedBytes = dataBytes
            } else {
                failed = true
                Log.error("Could not update the WAV header of \(url.lastPathComponent) — dropping further audio for this file.")
                return false
            }
        }
        return true
    }

    /// ~10 s of audio between in-flight header patches (two 4-byte writes).
    private var patchInterval: UInt32 { UInt32(sampleRate * channels * 2 * 10) }

    private func patchHeader() throws {
        var sizes = Data(count: 8)
        write(&sizes, 0, UInt32(36) + dataBytes)        // RIFF chunk size
        write(&sizes, 4, dataBytes)                     // data chunk size
        try handle.seek(toOffset: 4)
        try handle.write(contentsOf: sizes.subdata(in: 0..<4))
        try handle.seek(toOffset: 40)
        try handle.write(contentsOf: sizes.subdata(in: 4..<8))
    }

    /// Seconds of audio written so far.
    var duration: Double { Double(totalFrames) / Double(sampleRate) }

    func close() {
        guard !closed else { return }
        closed = true
        do {
            try patchHeader()
        } catch {
            // Header patching rewrites existing bytes, so this is rare even
            // on a full disk; the file may be unreadable by strict parsers.
            Log.error("Could not finalize WAV header for \(url.lastPathComponent): \(error.localizedDescription)")
        }
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
