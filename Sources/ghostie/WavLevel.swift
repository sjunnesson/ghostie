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

    /// A track's loudness over time, one peak magnitude per window.
    ///
    /// `probe` answers "was this track ever connected to anything"; this
    /// answers the same question about one *span* of it, which is what the
    /// transcript needs. Whisper decodes whatever WAV it is handed, silence
    /// included, and invents plausible speech there — on the 2026-09-08 call
    /// it wrote 26 "Thank you." turns onto stretches of `participants.wav`
    /// that were exact zeros (Google Meet stops sending audio when nobody on
    /// the far side is talking). Words cannot come from zeros, so a segment
    /// whose own span never rose above the noise floor did not happen.
    struct Envelope {
        let windowMs: Int
        /// Largest absolute sample in each window, in Int16 units.
        let peaks: [Int]
        var seconds: Double { Double(peaks.count * windowMs) / 1000 }

        /// Loudest sample in `[fromMs, toMs)`, or 0 when the span is empty or
        /// lies past the end of the track. Windows that merely *overlap* the
        /// span count: a whisper timestamp is accurate to a few hundred
        /// milliseconds at best, and the whole point is to be slow to call
        /// something silent.
        func peak(fromMs: Int, toMs: Int) -> Int {
            guard let range = windows(fromMs: fromMs, toMs: toMs) else { return 0 }
            return peaks[range].max() ?? 0
        }

        /// Share of the span's windows carrying anything above `threshold`.
        ///
        /// This, not `peak`, is what tells a decoded utterance from a decoded
        /// silence — because whisper does not give a hallucination a short
        /// span. Measured on the 2026-09-08 call: every invented "Thank you."
        /// came back with an *exactly 30.00 s* span covering the whole quiet
        /// stretch, and one stray sample of 91 somewhere in those 30 seconds
        /// is enough to defeat a peak test. Over a span that long the
        /// question worth asking is not "was anything ever loud" but "was
        /// anything loud for any part of it".
        func activeFraction(fromMs: Int, toMs: Int,
                            threshold: Int = activeThreshold) -> Double {
            guard let range = windows(fromMs: fromMs, toMs: toMs) else { return 0 }
            let active = peaks[range].reduce(0) { $0 + ($1 >= threshold ? 1 : 0) }
            return Double(active) / Double(range.count)
        }

        /// Window indices overlapping `[fromMs, toMs)`, or nil when the span
        /// is empty or falls outside the track.
        private func windows(fromMs: Int, toMs: Int) -> ClosedRange<Int>? {
            guard !peaks.isEmpty, toMs > fromMs else { return nil }
            let first = max(0, fromMs / windowMs)
            let last = min(peaks.count - 1, (toMs - 1) / windowMs)
            return first <= last ? first...last : nil
        }

        /// Whether `[fromMs, toMs)` is inside the recording at all. A span
        /// past the end reads as silent for want of data, which is not the
        /// same claim and must not be treated as one.
        func covers(fromMs: Int, toMs: Int) -> Bool {
            guard !peaks.isEmpty, toMs > fromMs, fromMs >= 0 else { return false }
            return toMs <= peaks.count * windowMs
        }
    }

    /// Peak below this in a window counts as "nothing here" (≈ −42 dBFS).
    /// A live-but-idle microphone, a quiet room and a muted-but-connected
    /// participant all sit above it; conference audio that is simply not
    /// being sent sits below.
    static let activeThreshold = 256
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

    /// One streamed pass producing a peak-per-`windowMs` profile of the track.
    ///
    /// 50 ms is short enough that a two-word segment spans several windows and
    /// long enough that a 126-minute call costs ~150 k `Int`s. Returns nil for
    /// anything that is not a readable PCM WAV, which callers must treat as
    /// "no evidence" rather than as silence.
    /// Same profile over PCM already in memory. The code-switch path reads
    /// each track's PCM once and stitches from it; re-reading the WAV to
    /// profile it would double the I/O on a 240 MB file.
    static func envelope(pcm: Data, windowMs: Int = 50) -> Envelope? {
        guard windowMs > 0, !pcm.isEmpty else { return nil }
        let perWindow = max(1, sampleRate * windowMs / 1000)
        var peaks: [Int] = []
        peaks.reserveCapacity(pcm.count / 2 / perWindow + 1)
        pcm.withUnsafeBytes { raw in
            var windowPeak = 0, fill = 0
            for i in 0..<(raw.count / 2) {
                let magnitude = Int(raw.loadUnaligned(fromByteOffset: i * 2,
                                                      as: Int16.self).magnitude)
                if magnitude > windowPeak { windowPeak = magnitude }
                fill += 1
                if fill == perWindow { peaks.append(windowPeak); windowPeak = 0; fill = 0 }
            }
            if fill > 0 { peaks.append(windowPeak) }
        }
        return peaks.isEmpty ? nil : Envelope(windowMs: windowMs, peaks: peaks)
    }

    static func envelope(_ url: URL, windowMs: Int = 50) -> Envelope? {
        guard windowMs > 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let dataOffset = try? dataChunkOffset(handle) else { return nil }
        try? handle.seek(toOffset: dataOffset)

        let perWindow = max(1, sampleRate * windowMs / 1000)
        var peaks: [Int] = []
        var windowPeak = 0
        var windowFill = 0
        var carry: UInt8?

        while true {
            guard let chunk = try? handle.read(upToCount: readChunkBytes),
                  !chunk.isEmpty else { break }
            var bytes = chunk
            if let c = carry { bytes.insert(c, at: bytes.startIndex); carry = nil }
            if bytes.count % 2 == 1 { carry = bytes.removeLast() }
            bytes.withUnsafeBytes { raw in
                for i in 0..<(raw.count / 2) {
                    let magnitude = Int(raw.loadUnaligned(fromByteOffset: i * 2,
                                                          as: Int16.self).magnitude)
                    if magnitude > windowPeak { windowPeak = magnitude }
                    windowFill += 1
                    if windowFill == perWindow {
                        peaks.append(windowPeak)
                        windowPeak = 0
                        windowFill = 0
                    }
                }
            }
        }
        if windowFill > 0 { peaks.append(windowPeak) }
        return peaks.isEmpty ? nil : Envelope(windowMs: windowMs, peaks: peaks)
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
