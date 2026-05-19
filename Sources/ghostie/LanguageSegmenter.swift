import Foundation

/// Phase 1 + 2 of the code-switching pipeline: turn a track into VAD speech
/// segments, then label each segment's language *without decoding it*.
///
/// Both steps shell out to the same `whisper-cli` already on disk (Option A in
/// code-switching.md — no new ONNX dependency). Segmentation reads VAD-driven
/// segment offsets from whisper's JSON; detection uses `--detect-language` on
/// an in-place `--offset-t`/`--duration-t` slice (no WAV splicing).
struct LanguageSegmenter {
    let config: Config
    var cs: CodeSwitchConfig { config.codeSwitch }

    enum SegmenterError: Error, LocalizedError {
        case whisperUnavailable
        case vadModelMissing(String)
        case whisperFailed(Int32, String)
        var errorDescription: String? {
            switch self {
            case .whisperUnavailable:
                return "whisper.cpp not set up for code-switching (run scripts/setup.sh --codeswitch)"
            case .vadModelMissing(let p):
                return "code-switching requires the Silero VAD model (missing: \(p))"
            case .whisperFailed(let code, let out):
                return "whisper exited \(code): \(out.suffix(400))"
            }
        }
    }

    // MARK: Phase 1 — VAD segmentation

    /// Speech segments for `wav`, oldest first. Uses any model just to drive
    /// VAD; the segment text is discarded — only the offsets matter.
    func segments(for wav: URL) throws -> [VADSegment] {
        guard !config.whisperBinary.isEmpty,
              FileManager.default.isExecutableFile(atPath: config.whisperBinary) else {
            throw SegmenterError.whisperUnavailable
        }
        guard !config.vadModel.isEmpty,
              FileManager.default.fileExists(atPath: config.vadModel) else {
            throw SegmenterError.vadModelMissing(config.vadModel)
        }
        // Drive VAD with the balanced multilingual model (NOT KB-Whisper —
        // its language-ID head is Swedish-biased; segmentation only needs the
        // VAD offsets but we keep one model for both phases).
        let driverModel = detectionModel()
        guard !driverModel.isEmpty else { throw SegmenterError.whisperUnavailable }

        let prefix = wav.deletingPathExtension().path + ".vad"
        // NOTE: `-nt` must NOT be passed here — in this whisper-cli build it
        // collapses the VAD output into a single whole-file segment. Without
        // it the JSON keeps per-speech-region offsets, which is the point.
        let (status, out) = runWhisper([
            "-m", driverModel,
            "-f", wav.path,
            "-l", "auto",
            "--vad", "--vad-model", config.vadModel,
            "--vad-threshold", "0.5",
            "--vad-min-speech-duration-ms", "250",
            "--vad-min-silence-duration-ms", "350",
            "-oj", "-of", prefix,
            "-np"
        ])
        guard status == 0 else { throw SegmenterError.whisperFailed(status, out) }
        let segs = Self.parseSegments(URL(fileURLWithPath: prefix + ".json"))
        try? FileManager.default.removeItem(atPath: prefix + ".json")
        // Defensive: VAD min-speech is 250 ms, but drop anything shorter.
        return segs.filter { $0.durationMs >= 250 }
    }

    /// Parse `transcription[].offsets.{from,to}` (ms) into VAD segments.
    static func parseSegments(_ url: URL) -> [VADSegment] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["transcription"] as? [[String: Any]] else { return [] }
        var out: [VADSegment] = []
        for item in items {
            guard let off = item["offsets"] as? [String: Any] else { continue }
            let from = intValue(off["from"]) ?? 0
            let to = intValue(off["to"]) ?? from
            if to > from { out.append(VADSegment(startMs: from, endMs: to)) }
        }
        return out.sorted { $0.startMs < $1.startMs }
    }

    // MARK: Phase 2 — per-segment language detection

    /// Label every segment with a whitelist language or `unknown`. Segments
    /// shorter than `minDetectMs` are `unknown` *without* invoking whisper —
    /// this is why backchannels ("mm", "ja", "yeah") never fake a switch.
    ///
    /// IMPORTANT: this whisper-cli's `--detect-language` ignores
    /// `--offset-t`/`--duration` and always detects from the *file start*
    /// (verified: identical p for every offset). So each segment is physically
    /// sliced to a temp WAV and detected on that — the only reliable Option-A
    /// path. Track PCM is read once, not per segment.
    func detect(_ segs: [VADSegment], in wav: URL) throws -> [LanguageDetection] {
        let model = detectionModel()
        guard !model.isEmpty else { throw SegmenterError.whisperUnavailable }
        guard segs.contains(where: { $0.durationMs >= cs.minDetectMs }) else {
            return segs.map(unknownDetection)
        }
        let pcm = (try? AudioStitcher.readPCM(wav)) ?? Data()
        let bytesPerMs = 16_000 * 2 / 1000   // 16 kHz mono Int16
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostie-detect-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        var dets: [LanguageDetection] = []
        for (idx, s) in segs.enumerated() {
            if s.durationMs < cs.minDetectMs || pcm.isEmpty {
                dets.append(unknownDetection(s)); continue
            }
            let lo = min(pcm.count, s.startMs * bytesPerMs)
            let hi = min(pcm.count, lo + min(s.durationMs, 30_000) * bytesPerMs)
            guard hi > lo else { dets.append(unknownDetection(s)); continue }
            let slice = scratch.appendingPathComponent("seg\(idx).wav")
            do { try AudioStitcher.writeWAV(pcm.subdata(in: lo..<hi),
                                            to: slice, sampleRate: 16_000) }
            catch { dets.append(unknownDetection(s)); continue }
            let (status, out) = runWhisper([
                "-m", model, "-f", slice.path, "-l", "auto", "--detect-language"
            ])
            try? FileManager.default.removeItem(at: slice)
            guard status == 0,
                  let (lang, p) = Self.parseDetectedLanguage(out) else {
                dets.append(unknownDetection(s)); continue
            }
            dets.append(mapped(lang: lang, p: p, segment: s))
        }
        return dets
    }

    /// Map raw whisper language → whitelist. Nordic look-alikes collapse to
    /// `sv` (KB-Whisper / the lang head confuse no/da/nb/nn on short Swedish);
    /// anything off-whitelist is `unknown` so smoothing can absorb it.
    private func mapped(lang: String, p: Double, segment: VADSegment) -> LanguageDetection {
        let nordicToSv = ["sv", "no", "nb", "nn", "da", "no-no"]
        var top = lang.lowercased()
        if cs.languages.contains("sv"), nordicToSv.contains(top) { top = "sv" }
        guard cs.languages.contains(top) else { return unknownDetection(segment) }
        let conf = min(0.999, max(0.001, p))
        let lp: [String: Double] = [
            top: Foundation.log(conf),
            (cs.languages.first { $0 != top } ?? "en"): Foundation.log(1 - conf)
        ]
        let margin = lp[top]! - (lp.values.min() ?? lp[top]!)
        return LanguageDetection(segment: segment, top: top,
                                 confidence: conf, margin: margin, logprobs: lp)
    }

    private func unknownDetection(_ s: VADSegment) -> LanguageDetection {
        LanguageDetection(segment: s, top: LanguageDetection.unknown,
                          confidence: 0, margin: 0, logprobs: [:])
    }

    /// Parse whisper's auto-detect line, e.g.
    /// `whisper_full_with_state: auto-detected language: sv (p = 0.87)`
    /// or `detected language: en`. Returns (language, probability).
    static func parseDetectedLanguage(_ text: String) -> (String, Double)? {
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.lowercased()
            guard let r = l.range(of: "detected language:") else { continue }
            let rest = l[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let lang = rest.split(whereSeparator: { $0 == " " || $0 == "(" })
                .first.map(String.init), !lang.isEmpty else { continue }
            var p = 1.0
            if let pr = l.range(of: "p = ") ?? l.range(of: "p=") {
                let tail = l[pr.upperBound...]
                let num = tail.prefix { $0.isNumber || $0 == "." }
                p = Double(num) ?? 1.0
            }
            return (lang, p)
        }
        return nil
    }

    // MARK: whisper-cli plumbing

    /// Model used for VAD-driving *and* language detection. Must be a
    /// balanced multilingual model: KB-Whisper's language-ID head is
    /// Swedish-biased and detects English as `sv (p=1.0)`. Prefer the
    /// dominant-language model (en → vanilla large-v3), then any non-KB
    /// whitelist model, then the single-language `whisperModel`, and only
    /// fall back to a KB model if nothing else exists.
    private func detectionModel() -> String {
        let fm = FileManager.default
        let dom = cs.modelPath(for: cs.dominantLanguage)
        if (cs.modelPerLanguage[cs.dominantLanguage] ?? "") != "kb-whisper-large",
           fm.fileExists(atPath: dom) { return dom }
        for l in cs.languages where (cs.modelPerLanguage[l] ?? "") != "kb-whisper-large" {
            let p = cs.modelPath(for: l)
            if fm.fileExists(atPath: p) { return p }
        }
        if fm.fileExists(atPath: config.whisperModel) { return config.whisperModel }
        for l in cs.languages {
            let p = cs.modelPath(for: l)
            if fm.fileExists(atPath: p) { return p }
        }
        return ""
    }

    private func runWhisper(_ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.whisperBinary)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func intValue(_ any: Any?) -> Int? {
        (any as? Int) ?? (any as? NSNumber)?.intValue
            ?? (any as? String).flatMap { Int($0) }
    }
}
