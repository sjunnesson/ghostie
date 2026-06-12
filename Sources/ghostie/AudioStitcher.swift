import Foundation

/// Builds a single per-language WAV out of a track's language runs, separated
/// by true silence so whisper can't leak tokens across run boundaries, plus an
/// offset table to map decoded timestamps back to the original track timeline.
///
/// Ghostie's WAVs are always canonical 16 kHz mono Int16 PCM (see `WavWriter` /
/// `AudioChunkConverter`), so this slices the PCM natively — no ffmpeg
/// dependency, and it's deterministic enough to unit-test.
struct AudioStitcher {

    /// One run's placement inside the stitched WAV.
    struct OffsetEntry {
        let stitchedStartMs: Int
        let stitchedEndMs: Int
        let originalStartMs: Int   // run start in the source track
    }

    struct OffsetTable {
        let entries: [OffsetEntry]

        /// Map a timestamp on the stitched timeline back to the original
        /// track. Returns nil for timestamps that land in a silence pad
        /// (boundary noise — dropped).
        func toOriginal(_ stitchedMs: Int) -> Int? {
            for e in entries where stitchedMs >= e.stitchedStartMs
                && stitchedMs < e.stitchedEndMs {
                return e.originalStartMs + (stitchedMs - e.stitchedStartMs)
            }
            return nil
        }
    }

    struct Stitched {
        let url: URL
        let table: OffsetTable
    }

    enum StitchError: Error, LocalizedError {
        case unreadable(URL)
        case noRuns
        var errorDescription: String? {
            switch self {
            case .unreadable(let u): return "could not read PCM from \(u.lastPathComponent)"
            case .noRuns: return "no language runs to stitch"
            }
        }
    }

    let sampleRate = 16_000
    let bytesPerSample = 2

    /// Concatenate `runs` (already padded by the Smoother) into one WAV with
    /// `silencePadMs` of zeroes between consecutive runs.
    func stitch(track: URL, runs: [LanguageRun], to dest: URL,
                silencePadMs: Int) throws -> Stitched {
        try stitch(pcm: try Self.readPCM(track), runs: runs,
                   to: dest, silencePadMs: silencePadMs)
    }

    /// Same as `stitch(track:…)` but over already-read PCM, so a caller that
    /// holds the track's PCM (the codeswitch path reads it once per track) can
    /// stitch every per-language batch without re-reading and re-parsing the
    /// WAV from disk each time.
    func stitch(pcm: Data, runs: [LanguageRun], to dest: URL,
                silencePadMs: Int) throws -> Stitched {
        guard !runs.isEmpty else { throw StitchError.noRuns }
        let total = pcm.count / bytesPerSample

        func sampleIndex(_ ms: Int) -> Int {
            min(total, max(0, ms * sampleRate / 1000))
        }

        let padBytes = Data(count: max(0, silencePadMs) * sampleRate / 1000 * bytesPerSample)
        var body = Data()
        var entries: [OffsetEntry] = []
        let sorted = runs.sorted { $0.startMs < $1.startMs }

        for (i, run) in sorted.enumerated() {
            let lo = sampleIndex(run.startMs) * bytesPerSample
            let hi = sampleIndex(run.endMs) * bytesPerSample
            guard hi > lo else { continue }
            let stitchedStartMs = body.count / bytesPerSample * 1000 / sampleRate
            body.append(pcm.subdata(in: lo..<hi))
            let stitchedEndMs = body.count / bytesPerSample * 1000 / sampleRate
            entries.append(OffsetEntry(stitchedStartMs: stitchedStartMs,
                                       stitchedEndMs: stitchedEndMs,
                                       originalStartMs: run.startMs))
            if i < sorted.count - 1 { body.append(padBytes) }
        }
        try Self.writeWAV(body, to: dest, sampleRate: sampleRate)
        return Stitched(url: dest, table: OffsetTable(entries: entries))
    }

    // MARK: Minimal canonical-PCM WAV I/O

    /// Returns the raw PCM payload of a 16-bit WAV (scans chunks; tolerant of
    /// extra chunks before `data`).
    static func readPCM(_ url: URL) throws -> Data {
        guard let data = try? Data(contentsOf: url), data.count > 44 else {
            throw StitchError.unreadable(url)
        }
        func tag(_ off: Int) -> String {
            String(bytes: data[off..<off+4], encoding: .ascii) ?? ""
        }
        func u32(_ off: Int) -> Int {
            Int(data[off]) | Int(data[off+1]) << 8
                | Int(data[off+2]) << 16 | Int(data[off+3]) << 24
        }
        guard tag(0) == "RIFF", tag(8) == "WAVE" else {
            throw StitchError.unreadable(url)
        }
        var p = 12
        while p + 8 <= data.count {
            let id = tag(p)
            let size = u32(p + 4)
            let start = p + 8
            if id == "data" {
                let end = min(data.count, start + size)
                return data.subdata(in: start..<end)
            }
            p = start + size + (size & 1)   // chunks are word-aligned
        }
        throw StitchError.unreadable(url)
    }

    // MARK: Energy-trough detection (PR 4: snap-to-silence boundaries)
    //
    // Used by `CodeSwitchTranscriber` to place language-switch cut points at
    // real silence troughs rather than at the raw smoother boundary, which
    // can land mid-syllable. The decoder hallucinates duplicated half-words
    // when split mid-syllable; snapping to silence preserves word boundaries.

    /// Trough centers (ms from track start) within the half-open window
    /// [`loMs`, `hiMs`). A "trough" is a contiguous span of ≥ `minMs` of audio
    /// whose 20 ms-frame RMS sits below `thresholdDb` dBFS. Returns sorted
    /// centers; empty when no trough qualifies.
    ///
    /// Operates on canonical 16 kHz mono Int16-LE PCM (Ghostie's invariant).
    /// 20 ms frame size matches typical VAD granularity; smaller frames over-
    /// fragment, larger ones miss short word-boundary gaps. The caller passes
    /// an explicit window (e.g. bounded to the two runs being split) so a
    /// returned center can never land outside the span it's meant to divide.
    static func troughs(in pcm: Data,
                        loMs: Int,
                        hiMs: Int,
                        minMs: Int = 80,
                        thresholdDb: Double = -40) -> [Int] {
        let sampleRate = 16_000
        let frameMs = 20
        let frameSamples = sampleRate * frameMs / 1000   // 320
        let frameBytes = frameSamples * 2
        let bytesPerMs = sampleRate * 2 / 1000           // 32
        let lo = max(0, loMs * bytesPerMs)
        let hi = min(pcm.count, hiMs * bytesPerMs)
        guard hi > lo + frameBytes else { return [] }

        // Build a dBFS timeline (one entry per 20 ms frame). Bind the buffer
        // once for the whole scan instead of re-acquiring an unsafe pointer
        // per sample (tens of thousands of closure entries per boundary).
        var energies: [Double] = []
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var p = lo
            while p + frameBytes <= hi {
                var sum: Double = 0
                for i in 0..<frameSamples {
                    let s = Int16(littleEndian:
                        raw.loadUnaligned(fromByteOffset: p + i * 2, as: Int16.self))
                    let v = Double(s) / 32768.0
                    sum += v * v
                }
                let rms = (sum / Double(frameSamples)).squareRoot()
                energies.append(rms > 0 ? 20 * Foundation.log10(rms) : -200)
                p += frameBytes
            }
        }

        // Contiguous below-threshold runs ≥ minMs long → record center.
        // Floor at one frame so a misconfigured `minMs == 0` can't make every
        // single quiet frame qualify as a trough.
        var out: [Int] = []
        let framesInMin = max(1, (minMs + frameMs - 1) / frameMs)
        var i = 0
        while i < energies.count {
            if energies[i] < thresholdDb {
                var j = i
                while j + 1 < energies.count && energies[j + 1] < thresholdDb { j += 1 }
                if (j - i + 1) >= framesInMin {
                    let centerFrame = (i + j) / 2
                    let centerMs = (lo / bytesPerMs) + centerFrame * frameMs + frameMs / 2
                    out.append(centerMs)
                }
                i = j + 1
            } else {
                i += 1
            }
        }
        return out
    }

    static func writeWAV(_ pcm: Data, to url: URL, sampleRate: Int) throws {
        let channels = 1, bits = 16
        let byteRate = sampleRate * channels * bits / 8
        var h = Data()
        func a(_ s: String) { h.append(contentsOf: s.utf8) }
        func le32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func le16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        a("RIFF"); le32(UInt32(36 + pcm.count)); a("WAVE")
        a("fmt "); le32(16); le16(1); le16(UInt16(channels))
        le32(UInt32(sampleRate)); le32(UInt32(byteRate))
        le16(UInt16(channels * bits / 8)); le16(UInt16(bits))
        a("data"); le32(UInt32(pcm.count))
        try (h + pcm).write(to: url)
    }
}
