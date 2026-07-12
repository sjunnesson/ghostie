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
        let vox = VoxLingua107LID(modelPath: voxPath, remap: nordicRemap)
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

        var dets: [LanguageDetection] = []
        for s in segs {
            if s.durationMs < cs.minDetectMs || pcm.isEmpty {
                dets.append(unknownDetection(s)); continue
            }
            for chunk in Self.splitForDetect(s, maxMs: maxDetect) {
                let lo = min(pcm.count, chunk.startMs * bytesPerMs)
                let hi = min(pcm.count, lo + min(chunk.durationMs, 30_000) * bytesPerMs)
                guard hi > lo else { dets.append(unknownDetection(chunk)); continue }
                let slice = pcm.subdata(in: lo..<hi)
                let posterior: [String: Double]
                do {
                    posterior = try identifier.identify(pcm: slice,
                                                        sampleRateHz: 16_000,
                                                        restrict: whitelist)
                } catch let e as ClassifiableLIDError where e.isStructural {
                    // The identifier itself can't run (missing binary/model) —
                    // fail the call so Pipeline backlogs it for a clean retry,
                    // rather than silently labeling every segment unknown and
                    // mis-routing the whole track to the dominant language.
                    throw SegmenterError.whisperUnavailable
                } catch {
                    dets.append(unknownDetection(chunk)); continue
                }
                dets.append(Self.detection(from: posterior,
                                           whitelist: whitelist,
                                           segment: chunk))
            }
        }
        return dets
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
    static func resolveDetectionModel(config: Config,
                                      installed: InstalledModels) -> String {
        let fm = FileManager.default
        let cs = config.codeSwitch
        let languages = cs.effectiveLanguages(installed: installed)
        // A usable detection driver must be a balanced multilingual model:
        // KB-Whisper's language head is sv-biased and base.en can't detect
        // non-English at all, so `Models.isBadLIDDriver` rules both out even
        // when they're the only model installed for their language.
        func lidDriver(for lang: String) -> String? {
            guard let p = cs.effectiveModelPath(for: lang, installed: installed),
                  fm.fileExists(atPath: p), !Models.isBadLIDDriver(path: p) else { return nil }
            return p
        }
        if let dom = lidDriver(for: cs.dominantLanguage) { return dom }
        for l in languages {
            if let p = lidDriver(for: l) { return p }
        }
        if fm.fileExists(atPath: config.whisperModel),
           !Models.isBadLIDDriver(path: config.whisperModel) {
            return config.whisperModel
        }
        // Last resort: any installed model, even a biased one. Detection will
        // be poor, but segmentation only needs VAD offsets, so a single-model
        // install can still run rather than failing the whole call.
        for l in languages {
            if let p = cs.effectiveModelPath(for: l, installed: installed),
               fm.fileExists(atPath: p) {
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
