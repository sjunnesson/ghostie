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

    /// Set by `ghostie transcribe-probe` only: collects what each stage saw
    /// and how long it took, so a change to detection or decoding can be
    /// measured on a kept recording instead of argued about. nil in every
    /// production path — nothing is recorded and nothing is paid for.
    var trace: CodeSwitchTrace? = nil

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

    /// `meVoice`, when given, reshapes the Me track's loudness envelope before
    /// the speech-bounded decode splices by it — `EchoGate.masking`, which
    /// zeroes the stretches where the mic heard only the far end's echo so
    /// whisper never decodes them. It has no effect with `decodeSpeechOnly`
    /// off, which decodes every run whole.
    func transcribeBoth(me: URL, participants: URL,
                        meVoice: ((WavLevel.Envelope) -> WavLevel.Envelope)? = nil)
        throws -> (me: [Transcriber.Segment], participants: [Transcriber.Segment]) {

        try preflightModels()
        if let done = transcribeDecodeFirst(me: me, participants: participants,
                                            meVoice: meVoice) {
            return done
        }
        // ONE identifier for the whole call: when it's a ServerWhisperLID the
        // resident whisper-server stays loaded across BOTH tracks' detect
        // passes (and the verify pass below), and this defer tears it down
        // exactly once whether we return or throw — a throw backlogs the call
        // and a retry starts a fresh server. (A hard crash skips the defer,
        // but the server's sh watchdog notices the dead parent and kills it.)
        let lid = LanguageSegmenter.defaultIdentifier(config: config, installed: installed)
        defer { lid.shutdown() }
        let seg = LanguageSegmenter(config: config, installed: installed, identifier: lid)

        trace?.identifier = lid.description
        let (meSegs, partSegs) = try trace.timed("vad") {
            try segmentBoth(seg, me: me, participants: participants)
        }
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

        let meDet = try trace.timed("detect") { try seg.detect(meSegs, pcm: mePcm) }
        let partDet = try trace.timed("detect") { try seg.detect(partSegs, pcm: partPcm) }
        trace?.detections["me"] = meDet
        trace?.detections["participants"] = partDet

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

        // One empty track beside a talkative one is not a quiet participant —
        // it is a capture that failed silently, and the note is about to be
        // written from half a conversation. `WavLevel` catches this on the
        // audio itself; say it here too, because this is the first moment the
        // *transcription* can see it, and it used to slip by as an INFO.
        let meEmpty = meRuns.isEmpty, partEmpty = partRuns.isEmpty
        let line = "Code-switching: Me \(runSummary(meRuns)), Participants \(runSummary(partRuns))."
        if meEmpty != partEmpty {
            Log.warn(line + " One track carries no speech at all — check that "
                + (meEmpty ? "the microphone was" : "system audio was")
                + " actually captured.")
        } else {
            Log.info(line)
        }

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

        trace?.runs["me"] = meVerified
        trace?.runs["participants"] = partVerified
        if trace?.stopAfterRouting == true { return ([], []) }

        let callID = me.deletingLastPathComponent().lastPathComponent
        let meOut = try trace.timed("decode") {
            try decode(runs: meVerified, pcm: mePcm,
                       callID: callID, tag: "me", voiceFilter: meVoice)
        }
        let partOut = try trace.timed("decode") {
            try decode(runs: partVerified, pcm: partPcm,
                       callID: callID, tag: "participants")
        }
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

    // MARK: Decode first, route by text

    /// The whole call through installed transducer models, with the language
    /// of each stretch read off the transcript (`TranscriptRouter`) and only
    /// the stretches in another language decoded again — by that language's
    /// own transducer when one is installed, else by whisper. No VAD pass and
    /// no per-segment language pass.
    ///
    /// nil means "not available here" — the feature is off, no model is
    /// installed for any of the call's languages, the ONNX Runtime is missing,
    /// or a model failed — and the caller runs the acoustic path unchanged.
    /// A transducer problem must never cost the call: whisper is still there.
    ///
    /// Not private: `Pipeline` also calls it for a one-language install, where
    /// there is nothing to route and it is simply the faster decoder — after
    /// checking the audio really is in that language (see `confirms`).
    func transcribeDecodeFirst(
        me: URL, participants: URL,
        meVoice: ((WavLevel.Envelope) -> WavLevel.Envelope)?
    ) -> (me: [Transcriber.Segment], participants: [Transcriber.Segment])? {
        guard cs.transducerDecode else { return nil }
        let models = TransducerCatalog.installed()
        guard let home = TransducerCatalog.home(languages: languages, dominant: dominant,
                                                installed: models) else { return nil }
        if let pair = TranscriptRouter.lookalikes(in: languages) {
            Log.info("\(pair.0) and \(pair.1) are too close to tell apart from a transcript — the language of each stretch is decided from the audio; installed transducer models still do the decoding.")
            return nil
        }
        guard let runtime = ORTRuntime.shared else {
            Log.warn("Transducer decode is on but unavailable — \(ORTRuntime.unavailableReason). Using whisper for every language.")
            return nil
        }
        // One model in memory at a time, whichever stage asks.
        var loaded: (language: String, model: TransducerModel)?
        defer { loaded?.model.close() }
        func model(for language: String) throws -> TransducerModel {
            if let loaded, loaded.language == language { return loaded.model }
            loaded?.model.close()
            loaded = nil
            guard let directory = models[language] else {
                throw TransducerModel.ModelError.missing("no model for \(language)")
            }
            let fresh = try trace.timed("load") {
                try TransducerModel(directory: directory, runtime: runtime)
            }
            loaded = (language, fresh)
            return fresh
        }
        func name(_ language: String) -> String {
            ((models[language] ?? language) as NSString).lastPathComponent
        }

        let whitelist = languages
        let classify: (String) -> (language: String, confidence: Double)? = {
            TranscriptRouter.language(of: $0, among: whitelist)
        }
        var tracks: [FirstPass]
        do {
            trace?.identifier = "transcript routing over \(name(home))"
            // Sample each track with the home model to decide who decodes it…
            let sampler = try model(for: home)
            tracks = try trace.timed("transducer") {
                [try prepare(me, tag: "me", home: home, model: sampler, installed: Set(models.keys),
                             voiceFilter: meVoice, classify: classify),
                 try prepare(participants, tag: "participants", home: home, model: sampler,
                             installed: Set(models.keys), voiceFilter: nil, classify: classify)]
            }
            // One language set up, and not by name: make sure it is the
            // one being spoken before trusting this model with the call.
            if whitelist.count == 1, config.language.lowercased() != home {
                let samples = tracks.flatMap { $0.samples.map(\.text) }
                guard TranscriptRouter.confirms(samples, language: home, classify: {
                    TranscriptRouter.language(of: $0, among: [])
                }) else {
                    Log.info("Could not confirm this call is in \(home) from \(samples.count) samples — whisper decodes it.")
                    return nil
                }
            }
            // …then decode, the home model's tracks first since it is loaded.
            for language in [home] + whitelist.filter({ $0 != home }) {
                for index in tracks.indices where tracks[index].plan == .decode(language) {
                    guard !tracks[index].pieces.isEmpty else { continue }
                    let decoder = try model(for: language)
                    Log.info("\(tracks[index].tag): decoding \(tracks[index].heardMs / 60_000) min of speech with \(name(language)).")
                    tracks[index].segments = try trace.timed("transducer") {
                        TransducerText.segments(try transducerWords(
                            tracks[index].pieces, pcm: tracks[index].pcm, model: decoder,
                            cache: language == home ? tracks[index].sampled : [:],
                            language: language))
                    }
                }
            }
        } catch {
            Log.warn("Transducer decode failed (\(error.localizedDescription)) — using whisper for every language.")
            return nil
        }

        // A track that sampled as one other language skipped its first pass:
        // its samples still say what the conversation was in, and the whole
        // of it is one stretch for that language's model.
        func first(_ track: FirstPass) -> String? {
            if case .decode(let language) = track.plan { return language }
            return nil
        }
        let routed = TranscriptRouter.route(
            tracks: tracks.map { first($0) == nil ? [] : $0.segments },
            evidence: tracks.flatMap { first($0) == nil ? $0.samples : [] },
            homes: tracks.map { first($0) ?? home },
            languages: whitelist, classify: classify)

        var kept: [[Transcriber.Segment]] = []
        var redo: [[LanguageRun]] = []
        for (index, track) in tracks.enumerated() {
            if case .whole(let other) = track.plan {
                kept.append([])
                redo.append([LanguageRun(language: other, startMs: 0, endMs: track.durationMs, segments: [])])
                Log.info("\(track.tag): every sample reads as \(other) — the whole track goes to the \(other) model.")
            } else {
                kept.append(routed[index].kept)
                redo.append(routed[index].redo)
                if !track.segments.isEmpty {
                    let redoMs = routed[index].redo.reduce(0) { $0 + ($1.endMs - $1.startMs) }
                    let language = first(track) ?? home
                    Log.info("\(track.tag): \(track.segments.count) segments; "
                        + (redoMs == 0 ? "all of it reads as \(language)."
                           : "\(routed[index].redo.count) stretches (\(redoMs / 1000) s) read as another language and are decoded again."))
                }
            }
            trace?.runs[track.tag] = redo[index]
        }
        if trace?.stopAfterRouting == true { return (kept[0], kept[1]) }

        // Second decode: a stretch's own transducer where there is one…
        var out = kept
        let again = Set(redo.flatMap { $0.map(\.language) })
        for language in whitelist where again.contains(language) && models[language] != nil {
            do {
                let decoder = try model(for: language)
                var decoded: [[Transcriber.Segment]] = []
                try trace.timed("transducer") {
                    for (index, track) in tracks.enumerated() {
                        let runs = redo[index].filter { $0.language == language }
                        let spans = runs.flatMap {
                            AudioStitcher.spans(for: $0, voice: cs.decodeSpeechOnly ? track.voice : nil)
                        }
                        decoded.append(TransducerText.segments(
                            try transducerWords(chunks(spans, voice: track.voice), pcm: track.pcm,
                                                model: decoder, cache: [:], language: language)))
                    }
                }
                Log.info("Decoded the \(language) stretches with \(name(language)).")
                for index in tracks.indices {
                    out[index] += decoded[index]
                    redo[index].removeAll { $0.language == language }
                }
            } catch {
                // Its runs stay in `redo` and fall through to whisper below.
                Log.warn("The \(language) transducer failed (\(error.localizedDescription)) — whisper decodes those stretches.")
            }
        }
        loaded?.model.close()
        loaded = nil
        // …and whisper for the rest. From here a failure is whisper's, and
        // fails the call like any other whisper failure does on the acoustic
        // path: the caller falls back to that path, which throws and backlogs.
        let callID = me.deletingLastPathComponent().lastPathComponent
        for (index, track) in tracks.enumerated() where !redo[index].isEmpty {
            do {
                out[index] += try trace.timed("decode") {
                    try decode(runs: redo[index], pcm: track.pcm, callID: callID, tag: track.tag,
                               voiceFilter: track.tag == "me" ? meVoice : nil,
                               transducers: false)
                }
            } catch {
                Log.warn("Decoding the routed stretches failed (\(error.localizedDescription)) — using whisper for every language.")
                return nil
            }
        }
        return (out[0].sorted { $0.startMs < $1.startMs }, out[1].sorted { $0.startMs < $1.startMs })
    }

    /// One track on its way through the first decode.
    private struct FirstPass {
        let tag: String
        let pcm: Data
        let durationMs: Int
        /// The track's loudness (echo-masked for Me), nil for a silent track.
        var voice: WavLevel.Envelope? = nil
        /// The pieces of speech to decode, and their total length.
        var pieces: [(startMs: Int, endMs: Int)] = []
        var heardMs = 0
        /// Pieces the home model already decoded while sampling, by index.
        var sampled: [Int: [TransducerText.Word]] = [:]
        /// Those samples as text with their times — evidence for routing.
        var samples: [Transcriber.Segment] = []
        /// Who decodes the track first (or that nobody needs to).
        var plan: TranscriptRouter.Plan
        /// The first decode.
        var segments: [Transcriber.Segment] = []
    }

    /// Speech spans → the pieces a transducer is handed.
    private func chunks(_ spans: [(startMs: Int, endMs: Int)],
                        voice: WavLevel.Envelope?) -> [(startMs: Int, endMs: Int)] {
        let tune = ProcessInfo.processInfo.environment   // for scoring piece sizes against a reference
        return TransducerText.chunks(
            spans, voice: voice,
            maxMs: tune["GHOSTIE_TD_MAXMS"].flatMap(Int.init) ?? TransducerText.chunkMaxMs,
            joinGapMs: tune["GHOSTIE_TD_JOINGAP"].flatMap(Int.init) ?? TransducerText.chunkJoinGapMs)
    }

    /// Decode `chunks` of `pcm` into words on the track's clock. `cache`
    /// holds pieces already decoded (the samples), by index.
    private func transducerWords(_ chunks: [(startMs: Int, endMs: Int)], pcm: Data,
                                 model: TransducerModel,
                                 cache: [Int: [TransducerText.Word]],
                                 language: String?) throws -> [TransducerText.Word] {
        var all: [TransducerText.Word] = []
        for (i, chunk) in chunks.enumerated() {
            if let done = cache[i] { all += done; continue }
            let lo = min(pcm.count, chunk.startMs * 32), hi = min(pcm.count, chunk.endMs * 32)
            guard hi > lo else { continue }
            let samples: [Float] = pcm.subdata(in: lo..<hi).withUnsafeBytes { raw in
                raw.bindMemory(to: Int16.self).map { Float(Int16(littleEndian: $0)) / 32_768 }
            }
            all += TransducerText.words(try model.decode(samples: samples),
                                        vocabulary: model.vocabulary, offsetMs: chunk.startMs)
        }
        return language.map { TransducerText.withoutHesitations(all, language: $0) } ?? all
    }

    /// Read a track, find its speech, and sample it with the home model to
    /// decide which model decodes it first.
    private func prepare(_ wav: URL, tag: String, home: String, model: TransducerModel,
                         installed: Set<String>,
                         voiceFilter: ((WavLevel.Envelope) -> WavLevel.Envelope)?,
                         classify: (String) -> (language: String, confidence: Double)?)
        throws -> FirstPass {
        // A missing track (an imported recording has no me.wav) is silence.
        guard FileManager.default.fileExists(atPath: wav.path) else {
            return FirstPass(tag: tag, pcm: Data(), durationMs: 0, plan: .decode(home))
        }
        let pcm = try AudioStitcher.readPCM(wav)
        var pass = FirstPass(tag: tag, pcm: pcm, durationMs: pcm.count / 32, plan: .decode(home))
        var voice = WavLevel.envelope(pcm: pcm)
        if let filter = voiceFilter, let v = voice { voice = filter(v) }
        guard let voice, pass.durationMs > 0,
              voice.peaks.contains(where: { $0 >= AudioStitcher.voiceThreshold }) else { return pass }
        pass.voice = voice

        let whole = LanguageRun(language: home, startMs: 0, endMs: pass.durationMs, segments: [])
        pass.pieces = chunks(AudioStitcher.spans(for: whole, voice: cs.decodeSpeechOnly ? voice : nil),
                             voice: voice)
        pass.heardMs = pass.pieces.reduce(0) { $0 + ($1.endMs - $1.startMs) }

        // Sample before committing: an all-English track through the Swedish
        // model is two minutes spent on text that is all thrown away.
        let whitelist = languages
        for i in TranscriptRouter.probeIndices(pass.pieces) {
            // Unfiltered: these are cached as the home model's decode.
            pass.sampled[i] = try transducerWords([pass.pieces[i]], pcm: pcm, model: model,
                                                  cache: [:], language: nil)
        }
        pass.samples = pass.sampled.keys.sorted().map { i in
            Transcriber.Segment(startMs: pass.pieces[i].startMs,
                                text: pass.sampled[i]!.map(\.text).joined(separator: " "),
                                endMs: pass.pieces[i].endMs)
        }
        guard whitelist.count > 1 else { return pass }   // nothing to choose between
        pass.plan = TranscriptRouter.plan(pass.samples.map(\.text), home: home, languages: whitelist,
                                          installed: installed, classify: classify)
        return pass
    }

    // MARK: Per-track decode

    private func decode(runs: [LanguageRun], pcm: Data,
                        callID: String, tag: String,
                        voiceFilter: ((WavLevel.Envelope) -> WavLevel.Envelope)? = nil,
                        transducers: Bool = true)
        throws -> [Transcriber.Segment] {
        guard !runs.isEmpty else { return [] }
        // The track's loudness over time, so each run is spliced down to the
        // parts that carry speech. One pass over PCM already in memory.
        var voice = cs.decodeSpeechOnly ? WavLevel.envelope(pcm: pcm) : nil
        if let filter = voiceFilter, let v = voice { voice = filter(v) }
        // Filed under this process's PID so `sweepScratch` can tell a crashed
        // run's leftovers from a live one's (the app and a `ghostie process`
        // run can decode at the same time).
        let scratch = Self.scratchRoot.appendingPathComponent(
            "\(ProcessInfo.processInfo.processIdentifier)")
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
            // A language with its own transducer model is decoded by it; the
            // runs came from acoustic language ID, the decoder is the faster
            // one. Any failure leaves the language to whisper, below.
            if transducers, cs.transducerDecode,
               let segs = transducerDecode(langRuns, language: lang, pcm: pcm, voice: voice, tag: tag) {
                out += segs
                continue
            }
            let dest = scratch.appendingPathComponent("\(tag)-\(lang).wav")
            let stitched = try stitcher.stitch(pcm: pcm, runs: langRuns, to: dest,
                                               silencePadMs: cs.silencePadMs,
                                               voice: voice)
            if let voice {
                let spanned = langRuns.reduce(0) { total, run in
                    total + AudioStitcher.spans(for: run, voice: voice)
                        .reduce(0) { $0 + ($1.endMs - $1.startMs) }
                }
                let full = langRuns.reduce(0) { $0 + ($1.endMs - $1.startMs) }
                if full > 0, spanned < full {
                    Log.info("Speech-bounded decode (\(tag)-\(lang)): "
                        + "\(full / 60_000) min of run → \(spanned / 60_000) min of speech "
                        + "(\(100 - spanned * 100 / full)% less audio to decode).")
                }
            }
            let segs = try whisperDecode(stitched.url, language: lang)
            for s in segs {
                // Start and end each mapped onto the splice they belong to:
                // a segment crossing a splice must not keep the span of the
                // audio removed between them (`OffsetTable.span`).
                if let orig = stitched.table.span(stitchedStartMs: s.startMs,
                                                  stitchedEndMs: s.endMs) {
                    out.append(Transcriber.Segment(
                        startMs: orig.startMs, text: s.text, endMs: orig.endMs))
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

    /// `runs` of one language through its transducer model, or nil when
    /// there is none, the runtime is missing, or it failed.
    private func transducerDecode(_ runs: [LanguageRun], language: String, pcm: Data,
                                  voice: WavLevel.Envelope?, tag: String) -> [Transcriber.Segment]? {
        guard let directory = TransducerCatalog.installed()[language],
              let runtime = ORTRuntime.shared else { return nil }
        do {
            let model = try trace.timed("load") {
                try TransducerModel(directory: directory, runtime: runtime)
            }
            defer { model.close() }
            // The envelope places the cuts even when the whole run is decoded.
            let levels = voice ?? WavLevel.envelope(pcm: pcm)
            let spans = runs.flatMap { AudioStitcher.spans(for: $0, voice: voice) }
            Log.info("Decoding \(language) (\(tag)) with \((directory as NSString).lastPathComponent)…")
            return try trace.timed("transducer") {
                TransducerText.segments(try transducerWords(chunks(spans, voice: levels), pcm: pcm,
                                                            model: model, cache: [:],
                                                            language: language))
            }
        } catch {
            Log.warn("The \(language) transducer failed (\(error.localizedDescription)) — whisper decodes \(language).")
            return nil
        }
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
        Log.info("Decoding \(language) run-batch (\(wav.lastPathComponent))…")
        let status: Int32, out: String
        do {
            (status, out) = try runWatched(p, timeout: Transcriber.timeout(for: wav))
        } catch {
            throw CSError.whisperFailed(-1, error.localizedDescription)
        }
        guard status == 0 else { throw CSError.whisperFailed(status, out) }
        defer { try? FileManager.default.removeItem(atPath: prefix + ".json") }
        let segs = try Transcriber.parse(URL(fileURLWithPath: prefix + ".json"))
        return segs
    }

    // MARK: Helpers

    /// The VAD pass over both tracks. It only needs offsets, so it runs on the
    /// smallest installed model, and when that model is small the two tracks
    /// are segmented at the same time — two independent whisper-cli processes
    /// over different files. With only a large model installed they stay in
    /// series: two resident large models is exactly the peak-RAM spike the
    /// serial decode exists to avoid.
    private func segmentBoth(_ seg: LanguageSegmenter, me: URL, participants: URL)
        throws -> ([VADSegment], [VADSegment]) {
        let model = LanguageSegmenter.resolveSegmentationModel(config: config,
                                                               installed: installed)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: model))?[.size] as? Int64 ?? .max
        guard bytes <= Self.concurrentVADModelBytes else {
            return (try seg.segments(for: me), try seg.segments(for: participants))
        }
        var meResult: Result<[VADSegment], Error> = .success([])
        let group = DispatchGroup()
        DispatchQueue.global(qos: .userInitiated).async(group: group) {
            meResult = Result { try seg.segments(for: me) }
        }
        let partResult = Result { try seg.segments(for: participants) }
        group.wait()       // both finish before either error is thrown
        return (try meResult.get(), try partResult.get())
    }

    /// Up to this size (base/small-class models) the two VAD passes overlap.
    static let concurrentVADModelBytes: Int64 = 600_000_000

    static let scratchRoot = URL(fileURLWithPath: "\(NSHomeDirectory())/.ghostie/scratch")

    /// Remove scratch left by processes that are gone — a crash mid-decode
    /// skips the `defer` that normally clears it, and stitched run-batches of
    /// a long call are hundreds of MB. Live processes' folders are kept.
    static func sweepScratch() {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: scratchRoot.path) else { return }
        for name in names {
            // Anything not named by a live PID (including the pre-per-process
            // loose files) is stale.
            if let pid = pid_t(name), kill(pid, 0) == 0 || errno == EPERM { continue }
            try? fm.removeItem(at: scratchRoot.appendingPathComponent(name))
        }
    }

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
