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
    /// Disk view used for whitelist + model resolution. Captured once at
    /// construction so a model file vanishing mid-call doesn't cause the
    /// segmenter and the decoder to disagree about what's installed.
    let installed: InstalledModels
    /// Pluggable LID. Defaults to `WhisperLID` driving the same `--detect-language`
    /// head Ghostie used pre-v2; v2 swaps in `VoxLingua107LID` once the ONNX
    /// framework lands. Tests inject a deterministic stub to exercise the
    /// segmenter→smoother path without a live whisper binary.
    let identifier: LanguageIdentifier
    var cs: CodeSwitchConfig { config.codeSwitch }
    var languages: [String] { cs.effectiveLanguages(installed: installed) }

    init(config: Config,
         installed: InstalledModels? = nil,
         identifier: LanguageIdentifier? = nil) {
        self.config = config
        let inst = installed ?? Models.installed(
            preferredKBVariant: config.codeSwitch.kbWhisperVariant)
        self.installed = inst
        self.identifier = identifier ?? Self.defaultIdentifier(config: config, installed: inst)
    }

    /// Pick the best LID for this install. Prefers the v2 ONNX identifier
    /// when its framework and model are present (the `isReady` check), and
    /// otherwise falls back to `WhisperLID` so behaviour is unchanged on a
    /// machine that hasn't installed the dedicated LID yet.
    ///
    /// The nordic-to-sv remap (KB-Whisper / the lang head confuse
    /// no/nb/nn/da on short Swedish) is baked into the WhisperLID at
    /// construction so the application-level policy lives next to the
    /// model decision, not in the segmenter's hot loop.
    static func defaultIdentifier(config: Config,
                                  installed: InstalledModels) -> LanguageIdentifier {
        let whitelist = config.codeSwitch.effectiveLanguages(installed: installed)
        let nordicRemap: (String) -> String = { raw in
            let lc = raw.lowercased()
            // Fold a Nordic look-alike into Swedish only when the user can't
            // actually decode that language. If they installed a Norwegian
            // model, `no` is in the whitelist and must reach its own model
            // rather than being silently rewritten to sv.
            let collapsible = ["no", "nb", "nn", "da", "no-no"]
            return collapsible.contains(lc) && whitelist.contains("sv") && !whitelist.contains(lc)
                ? "sv" : lc
        }
        // Prefer the dedicated ONNX LID when the runtime + exported model are
        // on this machine (fast on sub-2 s segments, no whisper spawn). The
        // disk is the switch: `brew install onnxruntime` + running
        // scripts/export-voxlingua-lid.py is all it takes; without them this
        // is a cheap file-existence check and the whisper path runs unchanged.
        let voxPath = ProcessInfo.processInfo.environment["GHOSTIE_VOXLINGUA_MODEL"]
            ?? "\(Config.modelsDir)/lid-voxlingua107.onnx"
        // NOTE: deliberately **no** `nordicRemap` here. The remap compensates
        // for whisper's language head, which genuinely confuses no/nb/nn/da
        // with short Swedish. VoxLingua107 is a 107-way classifier with real,
        // separately-trained Nordic classes, and `restrictedPosterior` folds
        // *mass* — so summing four sibling classes into `sv` systematically
        // out-votes the single `en` class on audio that is neither.
        // Measured on the 2026-08-28 all-English call: the remap turned 0/20
        // slices into 5/20 false Swedish at 8 s and 11/20 at 1.5 s, which is
        // what split that call into 84 alternating en/sv runs and decoded
        // English speech against the Swedish model. On genuinely Swedish
        // audio it buys nothing at 8 s (sv wins 20/20 either way, p(sv)=0.76
        // vs p(en)=0.00) and 3/20 at 1.5 s — nowhere near the cost.
        let vox = VoxLingua107LID(modelPath: voxPath)
        if vox.isReady { return vox }
        let driver = Self.resolveDetectionModel(config: config, installed: installed)
        // Prefer the resident whisper-server head: one model load per call
        // (~0.95 s) instead of one per segment (~4.8 s each via whisper-cli),
        // bit-identical probabilities. Construction is cheap — the server is
        // lazily spawned on the first identify, so building this for a
        // description (doctor) costs nothing. Falls back to WhisperLID when
        // the server binary isn't on this machine, so existing installs
        // never regress.
        if !config.whisperServerBinary.isEmpty,
           FileManager.default.isExecutableFile(atPath: config.whisperServerBinary),
           !driver.isEmpty, FileManager.default.fileExists(atPath: driver) {
            return ServerWhisperLID(serverBinary: config.whisperServerBinary,
                                    model: driver, remap: nordicRemap)
        }
        return WhisperLID(binary: config.whisperBinary, model: driver, remapTop: nordicRemap)
    }

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
        // Drive VAD with the *smallest* installed model: the segment offsets
        // come from the Silero VAD model (`--vad-model`), not the decoder, and
        // the decoded text is discarded, so decode quality — and even a biased
        // language head (KB-Whisper, base.en) — is irrelevant here. Only this
        // pass is downgraded; per-segment detection keeps the balanced LID
        // driver (see `resolveDetectionModel`).
        let driverModel = segmentationModel()
        guard !driverModel.isEmpty else { throw SegmenterError.whisperUnavailable }

        let prefix = wav.deletingPathExtension().path + ".vad"
        // NOTE: `-nt` must NOT be passed here — in this whisper-cli build it
        // collapses the VAD output into a single whole-file segment. Without
        // it the JSON keeps per-speech-region offsets, which is the point.
        let (status, out) = runWhisper([
            "-m", driverModel,
            "-f", wav.path,
            "-l", "auto",
            // The text is thrown away, so decode greedily (best-of 1, beam 1)
            // rather than paying default beam-search cost over the whole track.
            "-bo", "1", "-bs", "1",
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
    /// shorter than `minDetectMs` are `unknown` *without* invoking the LID —
    /// this is why backchannels ("mm", "ja", "yeah") never fake a switch.
    ///
    /// Segments longer than `maxDetectMs` are split into equal contiguous
    /// chunks and each chunk is labeled independently (see `splitForDetect`).
    /// One VAD segment can therefore yield several `LanguageDetection`s —
    /// that's the point: a language switch *inside* one long segment used to
    /// be averaged into a single label (from the first 30 s only, the LID
    /// slice cap), i.e. invisible. The smoother's hysteresis + snap-to-silence
    /// still own the final boundary placement, so finer detection granularity
    /// can't by itself introduce mid-word cuts.
    ///
    /// The LID model itself is held behind `self.identifier`; this method
    /// owns the per-segment slicing, the minDetectMs floor, and the
    /// pcm/segment plumbing only. Any LID error on one segment falls back to
    /// `unknownDetection` for that segment — the smoother absorbs holes.
    ///
    /// `pcm` is the track's canonical PCM, read once by the caller and shared
    /// with the snap/decode stages (no per-stage re-read of the WAV).
    func detect(_ segs: [VADSegment], pcm: Data) throws -> [LanguageDetection] {
        let whitelist = languages
        guard !whitelist.isEmpty else { return segs.map(unknownDetection) }
        guard segs.contains(where: { $0.durationMs >= cs.minDetectMs }) else {
            return segs.map(unknownDetection)
        }
        let bytesPerMs = 16_000 * 2 / 1000   // 16 kHz mono Int16
        // Floor the chunk size at 2×minDetectMs so a split can never produce
        // chunks below the detect floor (equal split of anything > maxMs
        // yields chunks > maxMs/2).
        let maxDetect = max(cs.maxDetectMs, 2 * cs.minDetectMs)

        // Sampled monolingual short-circuit. Under a slow identifier the full
        // pass below is the single most expensive stage in the whole pipeline
        // (measured 2026-08-28: 20 min of a 30 min run, on a call that turned
        // out to be English end to end), so ask a spread-out sample first.
        if let mono = try monolingualShortCircuit(segs, pcm: pcm, whitelist: whitelist,
                                                  maxDetect: maxDetect,
                                                  bytesPerMs: bytesPerMs) {
            return mono
        }

        var dets: [LanguageDetection] = []
        for s in segs {
            if s.durationMs < cs.minDetectMs || pcm.isEmpty {
                dets.append(unknownDetection(s)); continue
            }
            for chunk in Self.splitForDetect(s, maxMs: maxDetect) {
                let coarse: LanguageDetection
                do {
                    coarse = try coarseDetection(chunk, pcm: pcm, whitelist: whitelist,
                                                 bytesPerMs: bytesPerMs)
                } catch let e as ClassifiableLIDError where e.isStructural {
                    // The identifier itself can't run (missing binary/model) —
                    // fail the call so Pipeline backlogs it for a clean retry,
                    // rather than silently labeling every segment unknown and
                    // mis-routing the whole track to the dominant language.
                    throw SegmenterError.whisperUnavailable
                } catch {
                    dets.append(unknownDetection(chunk)); continue
                }
                // Fine pass: a switch can hide inside a long chunk (the
                // coarse label averages it away), and an ambiguous coarse
                // margin means the chunk may straddle one. Only under a
                // low-latency identifier — see `isLowLatency`.
                let ambiguous = coarse.top != LanguageDetection.unknown
                    && coarse.margin <= cs.intraSegmentMarginThreshold
                if identifier.isLowLatency,
                   chunk.durationMs > cs.intraSegmentRefineMs || ambiguous,
                   let refined = fineDetections(chunk: chunk, pcm: pcm,
                                                whitelist: whitelist,
                                                bytesPerMs: bytesPerMs),
                   refined.count > 1 {
                    dets.append(contentsOf: refined)
                } else {
                    dets.append(coarse)
                }
            }
        }
        return dets
    }

    /// One LID call on one chunk, converted to a detection. Throws only what
    /// the identifier throws (so the caller can tell a structural failure from
    /// a soft one); a slice that lands outside the PCM comes back `unknown`.
    private func coarseDetection(_ chunk: VADSegment, pcm: Data,
                                 whitelist: [String],
                                 bytesPerMs: Int) throws -> LanguageDetection {
        let lo = min(pcm.count, chunk.startMs * bytesPerMs)
        let hi = min(pcm.count, lo + min(chunk.durationMs, 30_000) * bytesPerMs)
        guard hi > lo else { return unknownDetection(chunk) }
        let posterior = try identifier.identify(pcm: pcm.subdata(in: lo..<hi),
                                                sampleRateHz: 16_000,
                                                restrict: whitelist)
        return Self.detection(from: posterior, whitelist: whitelist, segment: chunk)
    }

    // MARK: Monolingual fast path

    /// Segments to sample before deciding a track is monolingual, and the
    /// floor below which the sample isn't worth trusting. 24 probes at ~1.2 s
    /// (the whisper LIDs) is ~30 s — against ~10 min for the full pass on an
    /// hour-long track.
    static let monoProbeCount = 24
    static let monoProbeMinSamples = 8
    /// Every probe must clear this top1−top2 log-prob margin. exp(1.5) ≈ 4.5×,
    /// i.e. no probe was anywhere near a coin flip.
    static let monoProbeMinMargin = 1.5
    /// …and at most this share of probes may come back `unknown`. A track the
    /// LID keeps shrugging at is exactly the one not to generalise from.
    static let monoProbeMaxUnknown = 1.0 / 3.0

    /// Every segment labelled with the sample's aggregate posterior, or nil to
    /// run the full per-segment pass.
    ///
    /// Gated on `!identifier.isLowLatency` on purpose: the trade this makes is
    /// recall (a short stretch of the other language that no probe happened to
    /// land in) for time, and it is only ever worth making when the full pass
    /// costs tens of minutes. With the ONNX LID installed the full pass costs
    /// seconds, this returns nil, and nothing is traded.
    private func monolingualShortCircuit(_ segs: [VADSegment], pcm: Data,
                                         whitelist: [String],
                                         maxDetect: Int,
                                         bytesPerMs: Int) throws -> [LanguageDetection]? {
        guard cs.monolingualFastPath, !identifier.isLowLatency,
              whitelist.count > 1, !pcm.isEmpty else { return nil }
        let idx = Self.probeIndices(segs, minDetectMs: cs.minDetectMs,
                                    count: Self.monoProbeCount)
        guard idx.count >= Self.monoProbeMinSamples else { return nil }

        var probes: [LanguageDetection] = []
        for i in idx {
            // Probe the head of the segment — the same slice the full pass
            // would label it from (`splitForDetect` leaves the first chunk at
            // the segment start).
            let head = Self.splitForDetect(segs[i], maxMs: maxDetect)[0]
            do {
                probes.append(try coarseDetection(head, pcm: pcm, whitelist: whitelist,
                                                  bytesPerMs: bytesPerMs))
            } catch let e as ClassifiableLIDError where e.isStructural {
                throw SegmenterError.whisperUnavailable
            } catch {
                probes.append(unknownDetection(head))
            }
        }

        guard let lang = Self.monolingualVerdict(probes,
                                                 minSamples: Self.monoProbeMinSamples,
                                                 minMargin: Self.monoProbeMinMargin,
                                                 maxUnknownFraction: Self.monoProbeMaxUnknown),
              let agg = Self.aggregate(probes.filter { $0.top != LanguageDetection.unknown }
                                              .map(\.logprobs))
        else {
            Log.info("Language probe: \(idx.count) samples were not unanimous — running the full per-segment pass.")
            return nil
        }
        Log.info("Language probe: \(idx.count) samples across the track all read \(lang) — skipping per-segment detection.")
        // Every segment carries the sample's aggregate posterior: it is the
        // evidence we actually have, and it gives the smoother a real margin
        // to collapse the track into one run with.
        return segs.map { Self.detection(from: agg, whitelist: whitelist, segment: $0) }
    }

    /// Indices of up to `count` detect-eligible segments spread evenly across
    /// `segs`, sampled at the midpoint of each bucket so the head and tail of
    /// the track are both represented. Static + pure for the selftest.
    static func probeIndices(_ segs: [VADSegment], minDetectMs: Int, count: Int) -> [Int] {
        guard count > 0 else { return [] }
        let eligible = segs.indices.filter { segs[$0].durationMs >= minDetectMs }
        guard eligible.count > count else { return eligible }
        return (0..<count).map { eligible[(2 * $0 + 1) * eligible.count / (2 * count)] }
    }

    /// The one language a probe sample proves the whole track is in, or nil.
    ///
    /// Deliberately unanimous-or-nothing: a false positive routes a whole
    /// track to the wrong model and mistranscribes the other language with no
    /// signal anywhere, which is far worse than the minutes the fast path
    /// saves. Every usable probe must agree, every one of them must clear
    /// `minMargin`, and too many `unknown`s disqualify the sample outright.
    /// Static + pure for the selftest.
    static func monolingualVerdict(_ probes: [LanguageDetection],
                                   minSamples: Int,
                                   minMargin: Double,
                                   maxUnknownFraction: Double) -> String? {
        guard probes.count >= minSamples else { return nil }
        let known = probes.filter { $0.top != LanguageDetection.unknown }
        guard !known.isEmpty,
              Double(probes.count - known.count) / Double(probes.count) <= maxUnknownFraction,
              Set(known.map(\.top)).count == 1,
              known.allSatisfy({ $0.margin >= minMargin }) else { return nil }
        return known[0].top
    }

    // MARK: Fine (sliding-window) LID pass

    /// Re-LID `chunk` with overlapping `lidWindowMs × lidHopMs` windows,
    /// find sustained language change points on the posterior timeline
    /// (`changePoints`), and return one aggregated detection per sub-span.
    /// nil / single-element results mean "no sustained switch inside" — the
    /// caller keeps the coarse detection. Window-level identifier errors
    /// just drop that window; boundaries come only from evidence we have.
    private func fineDetections(chunk: VADSegment, pcm: Data,
                                whitelist: [String],
                                bytesPerMs: Int) -> [LanguageDetection]? {
        let windowMs = max(200, cs.lidWindowMs)
        let hopMs = max(100, min(cs.lidHopMs, windowMs))
        guard chunk.durationMs >= windowMs else { return nil }
        var windows: [(segment: VADSegment, logprobs: [String: Double])] = []
        var start = chunk.startMs
        while start + windowMs <= chunk.endMs {
            let w = VADSegment(startMs: start, endMs: start + windowMs)
            let lo = min(pcm.count, w.startMs * bytesPerMs)
            let hi = min(pcm.count, w.endMs * bytesPerMs)
            if hi > lo,
               let p = try? identifier.identify(pcm: pcm.subdata(in: lo..<hi),
                                                sampleRateHz: 16_000,
                                                restrict: whitelist) {
                windows.append((w, p))
            }
            start += hopMs
        }
        guard windows.count >= 2 else { return nil }
        let cuts = Self.changePoints(windows: windows, minDwellMs: cs.minDwellMs)
        guard !cuts.isEmpty else { return nil }

        // Split the chunk at the cut timestamps and aggregate each sub-span's
        // window posteriors (sum of log-probs = product of posteriors,
        // renormalized) into one detection.
        var bounds = [chunk.startMs] + cuts + [chunk.endMs]
        bounds = Array(Set(bounds)).sorted()
        var out: [LanguageDetection] = []
        for (lo, hi) in zip(bounds, bounds.dropFirst()) {
            let span = VADSegment(startMs: lo, endMs: hi)
            let inside = windows.filter {
                let center = ($0.segment.startMs + $0.segment.endMs) / 2
                return center >= lo && center < hi
            }.map(\.logprobs)
            guard let agg = Self.aggregate(inside) else {
                out.append(unknownDetection(span)); continue
            }
            out.append(Self.detection(from: agg, whitelist: whitelist, segment: span))
        }
        return out
    }

    /// CUSUM-style change-point scan over a fine-pass posterior timeline.
    /// Walks the windows tracking the current language (argmax of the first
    /// window); a candidate switch accumulates the per-window log-likelihood
    /// ratio `logP(candidate) − logP(current)`, and becomes a change point —
    /// placed at the START of the first window of the excursion — only when
    /// the accumulated evidence crosses `evidenceThreshold` AND the excursion
    /// has lasted `minDwellMs`. A single-window blip therefore never breaks
    /// a sentence, and a genuinely ambiguous stretch (ratios ≈ 0) never
    /// crosses the threshold. Static + pure for the selftest.
    static func changePoints(windows: [(segment: VADSegment, logprobs: [String: Double])],
                             minDwellMs: Int,
                             evidenceThreshold: Double = 2.0) -> [Int] {
        func top(_ lp: [String: Double]) -> String? {
            lp.max(by: { $0.value < $1.value })?.key
        }
        guard windows.count >= 2, var current = top(windows[0].logprobs) else { return [] }
        var out: [Int] = []
        var candidate: String?
        var excursionStart = 0
        var excursionCount = 0
        var evidence = 0.0
        for (i, w) in windows.enumerated() {
            guard let t = top(w.logprobs),
                  let curLp = w.logprobs[current],
                  let topLp = w.logprobs[t] else { continue }
            if t == current {
                candidate = nil; evidence = 0; excursionCount = 0
                continue
            }
            if candidate != t {
                candidate = t; evidence = 0; excursionStart = i; excursionCount = 0
            }
            evidence += topLp - curLp
            excursionCount += 1
            // Dwell needs corroboration: overlapping windows mean ONE window
            // spans a full `windowMs` by itself, so a single-window blip
            // would otherwise satisfy any minDwellMs ≤ the window width.
            let dwell = w.segment.endMs - windows[excursionStart].segment.startMs
            if evidence >= evidenceThreshold, dwell >= minDwellMs, excursionCount >= 2 {
                out.append(windows[excursionStart].segment.startMs)
                current = t
                candidate = nil; evidence = 0; excursionCount = 0
            }
        }
        return out
    }

    /// Product of posteriors in log space, renormalized (log-sum-exp). nil
    /// for an empty input or a degenerate (all -inf) result. Static + pure
    /// for the selftest.
    static func aggregate(_ posteriors: [[String: Double]]) -> [String: Double]? {
        guard !posteriors.isEmpty else { return nil }
        var sum: [String: Double] = [:]
        for p in posteriors {
            for (k, v) in p { sum[k, default: 0] += v }
        }
        guard let maxLp = sum.values.max(), maxLp > -.infinity else { return nil }
        let z = sum.values.reduce(0) { $0 + Foundation.exp($1 - maxLp) }
        guard z > 0 else { return nil }
        let logZ = maxLp + Foundation.log(z)
        return sum.mapValues { $0 - logZ }
    }

    /// Split one VAD segment into `ceil(duration / maxMs)` equal, contiguous
    /// chunks that exactly cover it. Segments at or under `maxMs` come back
    /// untouched. Equal division (not fixed-size + remainder) keeps every
    /// chunk > maxMs/2, so with `maxMs ≥ 2×minDetectMs` no chunk can fall
    /// under the detect floor. Static + pure for `runCodeSwitchSelfTest`.
    static func splitForDetect(_ s: VADSegment, maxMs: Int) -> [VADSegment] {
        guard maxMs > 0, s.durationMs > maxMs else { return [s] }
        let n = (s.durationMs + maxMs - 1) / maxMs
        var out: [VADSegment] = []
        var start = s.startMs
        for i in 1...n {
            let end = i == n ? s.endMs : s.startMs + s.durationMs * i / n
            out.append(VADSegment(startMs: start, endMs: end))
            start = end
        }
        return out
    }

    /// Convert an identifier's log-prob posterior into a `LanguageDetection`.
    /// `unknown` whenever the top is off-whitelist or all entries are
    /// `-Infinity` (the "identifier had no signal" floor).
    static func detection(from posterior: [String: Double],
                          whitelist: [String],
                          segment: VADSegment) -> LanguageDetection {
        guard let topEntry = posterior.max(by: { $0.value < $1.value }),
              topEntry.value > -.infinity,
              whitelist.contains(topEntry.key) else {
            return LanguageDetection(segment: segment, top: LanguageDetection.unknown,
                                     confidence: 0, margin: 0, logprobs: [:])
        }
        let top = topEntry.key
        let topLp = topEntry.value
        let secondLp = posterior.values.filter { $0 < topLp }.max() ?? -.infinity
        let conf = min(0.999, max(0.001, Foundation.exp(topLp)))
        let margin = topLp - (secondLp > -.infinity ? secondLp : topLp)
        return LanguageDetection(segment: segment, top: top,
                                 confidence: conf, margin: margin, logprobs: posterior)
    }

    private func unknownDetection(_ s: VADSegment) -> LanguageDetection {
        LanguageDetection(segment: s, top: LanguageDetection.unknown,
                          confidence: 0, margin: 0, logprobs: [:])
    }

    // MARK: whisper-cli plumbing

    /// Model used for per-segment language detection (and as the VAD pass's
    /// last-resort fallback — see `resolveSegmentationModel`). Must be a
    /// balanced multilingual model: KB-Whisper's language-ID head is
    /// Swedish-biased and detects English as `sv (p=1.0)`. Prefer the
    /// dominant-language model (en → vanilla large-v3), then any non-KB
    /// effective-whitelist model, then the single-language `whisperModel`,
    /// and only fall back to a KB model if nothing else exists.
    ///
    /// Reads from `effectiveModelPath(for:installed:)` so removing a model
    /// from disk removes it from the candidate list with no config edit.
    /// Static so the `defaultIdentifier` factory (called during init) can
    /// reach it without a fully-constructed `self`.
    /// `present` is the on-disk existence test, injected so `LanguageSetup`
    /// (and its self-tests) can ask *the same function* which model will drive
    /// detection without touching the filesystem — Settings must not
    /// re-implement this rule, or it will drift from what the call actually does.
    static func resolveDetectionModel(config: Config,
                                      installed: InstalledModels,
                                      present: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> String {
        let cs = config.codeSwitch
        let languages = cs.effectiveLanguages(installed: installed, present: present)
        // A usable detection driver must be a balanced multilingual model:
        // KB-Whisper's language head is sv-biased and base.en can't detect
        // non-English at all, so `Models.isBadLIDDriver` rules both out even
        // when they're the only model installed for their language.
        func lidDriver(for lang: String) -> String? {
            guard let p = cs.effectiveModelPath(for: lang, installed: installed, present: present),
                  present(p), !Models.isBadLIDDriver(path: p) else { return nil }
            return p
        }
        if let dom = lidDriver(for: cs.dominantLanguage) { return dom }
        for l in languages {
            if let p = lidDriver(for: l) { return p }
        }
        if present(config.whisperModel), !Models.isBadLIDDriver(path: config.whisperModel) {
            return config.whisperModel
        }
        // Last resort: any installed model, even a biased one. Detection will
        // be poor, but segmentation only needs VAD offsets, so a single-model
        // install can still run rather than failing the whole call.
        for l in languages {
            if let p = cs.effectiveModelPath(for: l, installed: installed, present: present),
               present(p) {
                return p
            }
        }
        return ""
    }

    /// Model used to *drive* the VAD/segmentation pass only. The offsets come
    /// from the Silero VAD model, not the decoder, and the decoded text is
    /// discarded — so the cheapest installed decode model is the right choice
    /// (even an LID-unsuitable one like base.en). Ranked by actual on-disk
    /// size, not catalog `approxBytes`: custom catalog entries can carry
    /// `approxBytes == 0` and would otherwise fake "smallest". Falls back to
    /// the LID driver so an install whose only model lives outside the catalog
    /// (a custom `whisperModel` path) still segments instead of failing.
    static func resolveSegmentationModel(config: Config,
                                         installed: InstalledModels) -> String {
        let fm = FileManager.default
        var smallest: (path: String, bytes: Int64)?
        for m in Models.allDecodeModels {
            guard let attrs = try? fm.attributesOfItem(atPath: m.destPath),
                  let bytes = attrs[.size] as? Int64 else { continue }
            if smallest == nil || bytes < smallest!.bytes {
                smallest = (m.destPath, bytes)
            }
        }
        if let smallest { return smallest.path }
        return resolveDetectionModel(config: config, installed: installed)
    }

    /// Instance-side wrapper for VAD segmentation (still needs whisper-cli).
    private func segmentationModel() -> String {
        Self.resolveSegmentationModel(config: config, installed: installed)
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
