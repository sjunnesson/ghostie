import Foundation

/// Phase 4 orchestrator. Owns the segment → detect → smooth(×2 passes) →
/// stitch-by-language → decode-with-the-right-model → map-back dance for both
/// tracks, and hands Pipeline raw per-track segments so the existing
/// `TranscriptCleaner` + timestamp-merge stay exactly as they are.
///
/// Failure is all-or-nothing per call: any whisper failure throws so Pipeline
/// queues the whole recording to the backlog and re-runs it cleanly later
/// (no partially-persisted codeswitch state — see code-switching.md gotchas).
struct CodeSwitchTranscriber {
    let config: Config
    var cs: CodeSwitchConfig { config.codeSwitch }

    enum CSError: Error, LocalizedError {
        case modelMissing(lang: String, path: String)
        case whisperFailed(Int32, String)
        var errorDescription: String? {
            switch self {
            case .modelMissing(let lang, let path):
                return "code-switching model for '\(lang)' not found at \(path) — run scripts/setup.sh --codeswitch"
            case .whisperFailed(let code, let out):
                return "whisper exited \(code): \(out.suffix(400))"
            }
        }
    }

    func transcribeBoth(me: URL, participants: URL)
        throws -> (me: [Transcriber.Segment], participants: [Transcriber.Segment]) {

        try preflightModels()
        let seg = LanguageSegmenter(config: config)

        let meSegs = try seg.segments(for: me)
        let partSegs = try seg.segments(for: participants)
        if meSegs.isEmpty && partSegs.isEmpty { return ([], []) }

        let meDet = try seg.detect(meSegs, in: me)
        let partDet = try seg.detect(partSegs, in: participants)

        let smMe = Smoother(config: cs, window: cs.smoothingWindowMe)
        let smPart = Smoother(config: cs, window: cs.smoothingWindowParticipants)

        // Pass 1 on both tracks, then Pass 2 each using the *other* track's
        // preliminary (never refined) timeline — no within-call feedback loop.
        let mePrelim = smMe.preliminary(meDet)
        let partPrelim = smPart.preliminary(partDet)
        let meRuns = smMe.refine(meDet, priorFrom: partPrelim)
        let partRuns = smPart.refine(partDet, priorFrom: mePrelim)

        Log.info("Code-switching: Me \(runSummary(meRuns)), Participants \(runSummary(partRuns)).")

        let callID = me.deletingLastPathComponent().lastPathComponent
        let meOut = try decode(track: me, runs: meRuns, callID: callID, tag: "me")
        let partOut = try decode(track: participants, runs: partRuns,
                                 callID: callID, tag: "participants")
        return (meOut, partOut)
    }

    // MARK: Per-track decode

    private func decode(track: URL, runs: [LanguageRun],
                        callID: String, tag: String) throws -> [Transcriber.Segment] {
        guard !runs.isEmpty else { return [] }
        let scratch = URL(fileURLWithPath: "\(NSHomeDirectory())/.ghostie/scratch")
            .appendingPathComponent(callID)
        try? FileManager.default.createDirectory(at: scratch,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let stitcher = AudioStitcher()
        // Group by language; off-whitelist runs fall back to the dominant model.
        let byLang = Dictionary(grouping: runs) { run -> String in
            cs.languages.contains(run.language) ? run.language : cs.dominantLanguage
        }

        var out: [Transcriber.Segment] = []
        // Serial within a track keeps peak RAM at one model.
        for lang in cs.languages where byLang[lang] != nil {
            guard let langRuns = byLang[lang], !langRuns.isEmpty else { continue }
            let dest = scratch.appendingPathComponent("\(tag)-\(lang).wav")
            let stitched = try stitcher.stitch(track: track, runs: langRuns,
                                               to: dest, silencePadMs: cs.silencePadMs)
            let segs = try whisperDecode(stitched.url, language: lang)
            for s in segs {
                if let orig = stitched.table.toOriginal(s.startMs) {
                    out.append(Transcriber.Segment(startMs: orig, text: s.text))
                }
                // segments inside the silence pads map to nil → dropped
            }
        }
        return dedupeBoundaries(out.sorted { $0.startMs < $1.startMs })
    }

    /// Decode one stitched, single-language WAV with that language's model.
    /// Same hardened decoding Ghostie already uses, plus an explicit
    /// `--language`, `--max-context 0` (no cross-run carry), and the
    /// model-specific prompt.
    private func whisperDecode(_ wav: URL, language: String) throws -> [Transcriber.Segment] {
        let model = cs.modelPath(for: language)
        let prefix = wav.deletingPathExtension().path
        var args = [
            "-m", model,
            "-f", wav.path,
            "-l", language,
            "-bo", "5", "-bs", "5",
            "-et", "2.40", "-lpt", "-1.00", "-nth", "0.60",
            "-sns",
            "-mc", "0",            // max-context 0 = no cross-run context carry
            "-oj", "-of", prefix,
            "-np"                  // keep timestamps: needed to map runs back
        ]
        let prompt = cs.prompt(for: language)
        if !prompt.isEmpty { args += ["--prompt", prompt] }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: config.whisperBinary)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        Log.info("Decoding \(language) run-batch (\(wav.lastPathComponent))…")
        do { try p.run() } catch {
            throw CSError.whisperFailed(-1, error.localizedDescription)
        }
        let outData = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw CSError.whisperFailed(p.terminationStatus,
                                        String(data: outData, encoding: .utf8) ?? "")
        }
        let segs = Transcriber.parse(URL(fileURLWithPath: prefix + ".json"))
        try? FileManager.default.removeItem(atPath: prefix + ".json")
        return segs
    }

    // MARK: Helpers

    private func preflightModels() throws {
        for l in cs.languages {
            let p = cs.modelPath(for: l)
            if !FileManager.default.fileExists(atPath: p) {
                throw CSError.modelMissing(lang: l, path: p)
            }
        }
    }

    private func runSummary(_ runs: [LanguageRun]) -> String {
        guard !runs.isEmpty else { return "no speech" }
        let counts = Dictionary(grouping: runs, by: \.language)
            .mapValues(\.count)
            .sorted { $0.key < $1.key }
            .map { "\($0.value)×\($0.key)" }
            .joined(separator: " ")
        return "\(runs.count) runs (\(counts))"
    }

    /// Run boundaries can clip a word and produce a duplicated half-word on
    /// each side. Drop a segment whose normalized text is (near-)equal to its
    /// time-adjacent predecessor — conservative, so real repeats survive.
    private func dedupeBoundaries(_ segs: [Transcriber.Segment]) -> [Transcriber.Segment] {
        guard segs.count > 1 else { return segs }
        func toks(_ s: String) -> [String] {
            s.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }
        var out: [Transcriber.Segment] = [segs[0]]
        for s in segs.dropFirst() {
            let prev = out.last!
            let a = toks(prev.text), b = toks(s.text)
            let adjacent = abs(s.startMs - prev.startMs) <= 1500
            if adjacent, !a.isEmpty, !b.isEmpty {
                let overlap = Double(Set(a.suffix(2)).intersection(Set(b.prefix(2))).count)
                let denom = Double(min(2, min(a.count, b.count)))
                if a == b || (denom > 0 && overlap / denom > 0.5) { continue }
            }
            out.append(s)
        }
        return out
    }
}
