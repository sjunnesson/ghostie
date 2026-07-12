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

    /// Snapshot of "what's on disk right now". Resolved once at the top of
    /// `transcribeBoth` so the same view drives preflight, language whitelist,
    /// model routing, and the doctor surface — no drift between layers.
    let installed: InstalledModels

    /// Optional LID for the post-decode verification pass (PR 5). When nil,
    /// `verifyRunLanguages` builds the default identifier on demand. Tests
    /// inject a deterministic stub here to assert the re-route contract
    /// without spinning up whisper-cli.
    let verifier: LanguageIdentifier?

    init(config: Config,
         installed: InstalledModels? = nil,
         verifier: LanguageIdentifier? = nil) {
        self.config = config
        self.installed = installed ?? Models.installed(
            preferredKBVariant: config.codeSwitch.kbWhisperVariant)
        self.verifier = verifier
    }

    /// Languages this call will actually label audio with — `cs.languages`
    /// filtered against installed models, or installed if `cs.languages` is
    /// empty. The single source of truth for downstream consumers: the
    /// segmenter, the smoother, the verifier, and the decoder all read this,
    /// so none of them can label or route a run to a language another stage
    /// can't handle.
    var languages: [String] { cs.effectiveLanguages(installed: installed) }

    /// `dominantLanguage` clamped into `languages`, so the decode off-whitelist
    /// bucket and the smoother prior always point at an installed language.
    var dominant: String { cs.effectiveDominant(installed: installed) }

    enum CSError: Error, LocalizedError {
        case noLanguagesInstalled
        case modelMissing(lang: String, path: String)
        case whisperFailed(Int32, String)
        var errorDescription: String? {
            switch self {
            case .noLanguagesInstalled:
                return "code-switching has no installed language models. Install at least one whisper model under ~/.ghostie/models/ (run scripts/setup.sh --codeswitch)."
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
        // ONE identifier for the whole call: when it's a ServerWhisperLID the
        // resident whisper-server stays loaded across BOTH tracks' detect
        // passes (and the verify pass below), and this defer tears it down
        // exactly once whether we return or throw — a throw backlogs the call
        // and a retry starts a fresh server. (A hard crash skips the defer,
        // but the server's sh watchdog notices the dead parent and kills it.)
        let lid = LanguageSegmenter.defaultIdentifier(config: config, installed: installed)
        defer { lid.shutdown() }
        let seg = LanguageSegmenter(config: config, installed: installed, identifier: lid)

        let meSegs = try seg.segments(for: me)
        let partSegs = try seg.segments(for: participants)
        if meSegs.isEmpty && partSegs.isEmpty { return ([], []) }

        // Read each track's PCM once here and thread it through detect → snap →
        // verify → decode, rather than re-reading (and re-parsing) the WAV at
        // every stage. ~60 MB for a 30-min track, previously decoded ~4× per
        // track; now once. An unreadable/corrupt WAV throws — which backlogs
        // the call for a clean retry — instead of degrading to empty PCM,
        // which used to make every segment detect as `unknown` and route the
        // whole track to the dominant language with no signal.
        let mePcm = try AudioStitcher.readPCM(me)
        let partPcm = try AudioStitcher.readPCM(participants)

        let meDet = try seg.detect(meSegs, pcm: mePcm)
        let partDet = try seg.detect(partSegs, pcm: partPcm)

        // Build the smoother with the SAME effective whitelist the segmenter
        // labels against (not raw cs.languages) so it can't emit a run in a
        // language the decoder has no model for.
        let smMe = Smoother(config: cs, languages: languages, window: cs.smoothingWindowMe)
        let smPart = Smoother(config: cs, languages: languages, window: cs.smoothingWindowParticipants)

        // Pass 1 on both tracks, then Pass 2 each using the *other* track's
        // preliminary (never refined) timeline — no within-call feedback loop.
        let mePrelim = smMe.preliminary(meDet)
        let partPrelim = smPart.preliminary(partDet)
        let meRuns = smMe.refine(meDet, priorFrom: partPrelim)
        let partRuns = smPart.refine(partDet, priorFrom: mePrelim)

        Log.info("Code-switching: Me \(runSummary(meRuns)), Participants \(runSummary(partRuns)).")

        // Snap each language-switch boundary to the nearest silence trough
        // (or merge the two runs when no trough lives in the search window).
        // Eliminates mid-syllable cuts that hurt the decoder.
        let meSnapped = snapBoundaries(meRuns, in: mePcm)
        let partSnapped = snapBoundaries(partRuns, in: partPcm)
        if meSnapped.count != meRuns.count || partSnapped.count != partRuns.count {
            Log.info("Snap-to-silence merged runs: Me \(meRuns.count)→\(meSnapped.count), Participants \(partRuns.count)→\(partSnapped.count).")
        }

        // Post-decode re-LID verification. After snap-to-silence the runs are
        // longer and cleaner than the per-VAD-segment evidence the smoother
        // saw, so re-checking each run with the LID catches the rare cases
        // where smoothing routed a run to the wrong model.
        let meVerified = verifyRunLanguages(meSnapped, in: mePcm, tag: "me", using: lid)
        let partVerified = verifyRunLanguages(partSnapped, in: partPcm,
                                              tag: "participants", using: lid)

        let callID = me.deletingLastPathComponent().lastPathComponent
        let meOut = try decode(runs: meVerified, pcm: mePcm,
                               callID: callID, tag: "me")
        let partOut = try decode(runs: partVerified, pcm: partPcm,
                                 callID: callID, tag: "participants")
        return (meOut, partOut)
    }

    /// Re-LID each run on its (snap-adjusted) audio and re-route runs whose
    /// LID winner sits at least `cs.verifyMarginDb` higher in log-prob than
    /// the originally-routed language. Returns the (possibly re-labeled)
    /// runs in original order.
    ///
    /// Public so the selftest can drive it with a deterministic stub
    /// identifier (no whisper-cli needed). `using` lets `transcribeBoth`
    /// share its per-call identifier (and its resident server) instead of
    /// building a second one here.
    func verifyRunLanguages(_ runs: [LanguageRun],
                            in pcm: Data,
                            tag: String = "",
                            using shared: LanguageIdentifier? = nil) -> [LanguageRun] {
        guard cs.verifyMarginDb > 0, runs.count >= 1, !pcm.isEmpty else { return runs }
        let active = languages
        guard active.count >= 2 else { return runs }
        // Precedence: injected test verifier → the caller's per-call
        // identifier → a locally-built default. Only the locally-built one is
        // ours to shut down (a resident server must not leak from this scope).
        let built: LanguageIdentifier? = (verifier == nil && shared == nil)
            ? LanguageSegmenter.defaultIdentifier(config: config, installed: installed)
            : nil
        defer { built?.shutdown() }
        let lid = verifier ?? shared ?? built!
        let bytesPerMs = 16_000 * 2 / 1000

        var out: [LanguageRun] = []
        for run in runs {
            let lo = min(pcm.count, run.startMs * bytesPerMs)
            // Cap the re-LID window: the language head doesn't benefit from
            // minutes of audio, so a long run only copies/decodes its first
            // 15 s rather than the whole span.
            let durMs = max(0, run.endMs - run.startMs)
            let hi = min(pcm.count, lo + min(durMs, 15_000) * bytesPerMs)
            guard hi > lo + bytesPerMs * 500 else { out.append(run); continue }
            let slice = pcm.subdata(in: lo..<hi)
            let posterior: [String: Double]
            do {
                posterior = try lid.identify(pcm: slice,
                                             sampleRateHz: 16_000,
                                             restrict: active)
            } catch {
                out.append(run); continue
            }
            guard let topEntry = posterior.max(by: { $0.value < $1.value }),
                  topEntry.value > -.infinity,
                  active.contains(topEntry.key) else {
                out.append(run); continue
            }
            // If the LID posterior has no mass for the currently-routed
            // language we have nothing to compare against — keep the run
            // rather than letting a `-inf` routedLp turn into a +inf margin
            // that force-re-routes past the verifyMarginDb gate.
            guard let routedLp = posterior[run.language] else { out.append(run); continue }
            let margin = topEntry.value - routedLp
            if topEntry.key != run.language, margin > cs.verifyMarginDb {
                let where_ = tag.isEmpty ? "" : "\(tag) "
                Log.info("Re-routing \(where_)run \(run.startMs)–\(run.endMs)ms: "
                    + "\(run.language) → \(topEntry.key) "
                    + "(LID margin \(String(format: "%.2f", margin)))")
                out.append(LanguageRun(language: topEntry.key,
                                       startMs: run.startMs,
                                       endMs: run.endMs,
                                       segments: run.segments))
            } else {
                out.append(run)
            }
        }
        return out
    }

    /// Walk adjacent runs and either (a) move the boundary to the nearest
    /// silence trough within `cs.snapSearchMs`, or (b) merge the two runs
    /// into the longer-duration language. Both rules avoid the failure mode
    /// where a language switch lands inside a syllable and the decoder
    /// produces duplicated half-words on either side.
    ///
    /// Public for selftest (`runCodeSwitchSelfTest` exercises it on
    /// synthetic PCM); the caller normally invokes it via `transcribeBoth`.
    func snapBoundaries(_ runs: [LanguageRun], in pcm: Data) -> [LanguageRun] {
        guard runs.count >= 2 else { return runs }
        var out = runs
        var i = 0
        while i + 1 < out.count {
            let a = out[i], b = out[i + 1]
            let boundary = (a.endMs + b.startMs) / 2
            // Bound the search to strictly inside the two runs. A trough within
            // ±snapSearchMs but outside [a.startMs, b.endMs] would otherwise
            // become an inverted boundary (endMs < startMs) that stitch()
            // silently drops, losing that run's audio.
            let loMs = max(a.startMs + 1, boundary - cs.snapSearchMs)
            let hiMs = min(b.endMs - 1, boundary + cs.snapSearchMs)
            let cand = loMs < hiMs
                ? AudioStitcher.troughs(in: pcm,
                                        loMs: loMs,
                                        hiMs: hiMs,
                                        minMs: cs.snapMinMs,
                                        thresholdDb: cs.snapEnergyDb)
                : []
            if let nearest = cand.min(by: { abs($0 - boundary) < abs($1 - boundary) }) {
                out[i] = LanguageRun(language: a.language,
                                     startMs: a.startMs,
                                     endMs: nearest,
                                     segments: a.segments)
                out[i + 1] = LanguageRun(language: b.language,
                                         startMs: nearest,
                                         endMs: b.endMs,
                                         segments: b.segments)
                i += 1
            } else {
                // No trough → merge into the longer run's language. Don't
                // advance i; the merged run may need to merge again with
                // out[i+1] if there's still no trough between them.
                let aLen = a.endMs - a.startMs, bLen = b.endMs - b.startMs
                let lang = aLen >= bLen ? a.language : b.language
                out[i] = LanguageRun(language: lang,
                                     startMs: a.startMs,
                                     endMs: b.endMs,
                                     segments: a.segments + b.segments)
                out.remove(at: i + 1)
            }
        }
        return out
    }

    // MARK: Per-track decode

    private func decode(runs: [LanguageRun], pcm: Data,
                        callID: String, tag: String) throws -> [Transcriber.Segment] {
        guard !runs.isEmpty else { return [] }
        let scratch = URL(fileURLWithPath: "\(NSHomeDirectory())/.ghostie/scratch")
            .appendingPathComponent(callID)
        try? FileManager.default.createDirectory(at: scratch,
                                                 withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let stitcher = AudioStitcher()
        // Group by language; off-whitelist runs fall back to the dominant
        // model. `dominant` is clamped into `active`, so the fallback bucket is
        // always one the `for lang in active` loop below actually visits — an
        // off-whitelist run can't be silently dropped.
        let active = languages
        let byLang = Dictionary(grouping: runs) { run -> String in
            active.contains(run.language) ? run.language : dominant
        }

        var out: [Transcriber.Segment] = []
        // Serial within a track keeps peak RAM at one model.
        for lang in active where byLang[lang] != nil {
            guard let langRuns = byLang[lang], !langRuns.isEmpty else { continue }
            let dest = scratch.appendingPathComponent("\(tag)-\(lang).wav")
            let stitched = try stitcher.stitch(pcm: pcm, runs: langRuns,
                                               to: dest, silencePadMs: cs.silencePadMs)
            let segs = try whisperDecode(stitched.url, language: lang)
            for s in segs {
                if let orig = stitched.table.toOriginal(s.startMs) {
                    out.append(Transcriber.Segment(startMs: orig, text: s.text))
                } else {
                    // Segments inside the silence pads map to nil. Usually
                    // whisper hallucinating into the gap — but if it decoded
                    // real speech there, silence would hide the loss, so
                    // leave an audit trail.
                    Log.warn("Code-switching: dropping segment decoded inside a \(tag)-\(lang) stitch pad (@\(s.startMs)ms): \"\(s.text.prefix(80))\"")
                }
            }
        }
        return dedupeBoundaries(out.sorted { $0.startMs < $1.startMs })
    }

    /// Decode one stitched, single-language WAV with that language's model.
    /// Same hardened decoding Ghostie already uses, plus an explicit
    /// `--language`, `--max-context 0` (no cross-run carry), and the
    /// model-specific prompt.
    private func whisperDecode(_ wav: URL, language: String) throws -> [Transcriber.Segment] {
        let model = cs.effectiveModelPath(for: language, installed: installed) ?? ""
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
        let active = languages
        if active.isEmpty { throw CSError.noLanguagesInstalled }
        for l in active {
            guard let p = cs.effectiveModelPath(for: l, installed: installed) else {
                throw CSError.modelMissing(lang: l, path: cs.modelPath(for: l))
            }
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
    // Internal (not private) for the selftest.
    func dedupeBoundaries(_ segs: [Transcriber.Segment]) -> [Transcriber.Segment] {
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
