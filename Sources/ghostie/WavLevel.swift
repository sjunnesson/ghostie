import Foundation

/// Cheap signal probe for the 16 kHz mono PCM WAVs the recorder writes.
///
/// Exists because a capture path can fail without failing: a stopped
/// `AVAudioEngine` graph, a muted or vanished input device, or denied
/// microphone permission all yield well-formed buffers of zeros. Conversion
/// succeeds, the WAV keeps pace with wall-clock, every existing watchdog stays
/// quiet — and the note that comes out reads like a complete record of a call
/// that was only ever half recorded. (2026-08-24: 59 minutes of digital
/// silence on `me.wav`, 82% of the local speaker's words lost, no warning.)
///
/// Reading is streamed — these files run to hundreds of megabytes.
enum WavLevel {

    struct Stats {
        let seconds: Double
        /// Largest absolute sample in the file. Exactly zero means the track
        /// is *digitally* silent: not a quiet room, which always carries a
        /// noise floor, but a source that was never connected to anything.
        let peak: Int
        /// Fraction of 100 ms windows carrying anything above the noise floor
        /// of a live-but-idle mic. Distinguishes "captured a quiet room" from
        /// "captured a muted device".
        let activeFraction: Double

        var isDigitalSilence: Bool { peak == 0 }
    }

    /// Peak below this in a 100 ms window counts as "nothing here" (≈ −42 dBFS).
    private static let activeThreshold = 256
    private static let sampleRate = 16_000
    private static let windowSamples = sampleRate / 10
    private static let readChunkBytes = 1 << 20

    static func probe(_ url: URL) -> Stats? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let dataOffset = try? dataChunkOffset(handle) else { return nil }
        try? handle.seek(toOffset: dataOffset)

        var peak = 0
        var totalSamples = 0
        var activeWindows = 0
        var totalWindows = 0
        var windowPeak = 0
        var windowFill = 0
        var carry: UInt8?

        func consume(_ sample: Int16) {
            let magnitude = Int(sample.magnitude)
            if magnitude > peak { peak = magnitude }
            if magnitude > windowPeak { windowPeak = magnitude }
            totalSamples += 1
            windowFill += 1
            if windowFill == windowSamples {
                totalWindows += 1
                if windowPeak >= activeThreshold { activeWindows += 1 }
                windowPeak = 0
                windowFill = 0
            }
        }

        while true {
            guard let chunk = try? handle.read(upToCount: readChunkBytes),
                  !chunk.isEmpty else { break }
            var bytes = chunk
            // A 1 MB read can split a frame; carry the orphan byte forward.
            if let c = carry { bytes.insert(c, at: bytes.startIndex); carry = nil }
            if bytes.count % 2 == 1 { carry = bytes.removeLast() }
            bytes.withUnsafeBytes { raw in
                let count = raw.count / 2
                for i in 0..<count {
                    consume(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
                }
            }
        }
        // A trailing partial window still counts — a 3 s file is all tail.
        if windowFill > 0 {
            totalWindows += 1
            if windowPeak >= activeThreshold { activeWindows += 1 }
        }

        return Stats(seconds: Double(totalSamples) / Double(sampleRate),
                     peak: peak,
                     activeFraction: totalWindows == 0
                        ? 0 : Double(activeWindows) / Double(totalWindows))
    }

    /// Walks the RIFF chunk list to the start of `data`. Ghostie's own writer
    /// always emits the canonical 44-byte header, but reading the list keeps
    /// the probe honest for anything else that lands in a session directory.
    private static func dataChunkOffset(_ handle: FileHandle) throws -> UInt64 {
        try handle.seek(toOffset: 0)
        guard let header = try handle.read(upToCount: 12), header.count == 12,
              header.prefix(4).elementsEqual(Array("RIFF".utf8)),
              header.suffix(4).elementsEqual(Array("WAVE".utf8)) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var offset: UInt64 = 12
        while true {
            try handle.seek(toOffset: offset)
            guard let head = try handle.read(upToCount: 8), head.count == 8 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let size = head.withUnsafeBytes {
                UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            }
            if head.prefix(4).elementsEqual(Array("data".utf8)) { return offset + 8 }
            // Chunks are word-aligned.
            offset += 8 + UInt64(size) + UInt64(size % 2)
        }
    }
}
