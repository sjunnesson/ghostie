import Foundation

/// Single source of truth for every model Ghostie can download: filename,
/// upstream URL, human label, approximate size for the UI. Anything that knows
/// where a model lives or how to fetch one reads from here.
///
/// Hash verification is not pinned: per design we trust Hugging Face's
/// `x-linked-etag` (a SHA256 of the file) captured at download time. The
/// captured etag is written to a `<filename>.meta` sidecar next to the model
/// so `ghostie doctor models` can re-verify on demand without a network round
/// trip.
struct Model {
    let filename: String
    let url: URL
    let label: String
    let approxBytes: Int64

    /// The language this model decodes best, for `InstalledModels` grouping.
    /// Empty for models that aren't a decode target (VAD).
    var language: String = ""

    /// Whether this model is a *balanced multilingual* one suitable for driving
    /// VAD and the `--detect-language` head. KB-Whisper's language head is
    /// Swedish-biased and the English-only `base.en` can't detect non-English,
    /// so both are `false`; `large-v3` is `true`. `resolveDetectionModel`
    /// filters on this instead of a hardcoded model-name compare.
    var goodForLID: Bool = false

    /// Whether this model can decode **any** Whisper language, not just
    /// `language`. True for the large-v3 family; false for a specialist like
    /// KB-Whisper (Swedish) or base.en (English only).
    ///
    /// This is what lets Ghostie offer a working default for German, Spanish,
    /// or anything else without shipping a separate model per language — the
    /// multilingual model people already have covers them. It deliberately does
    /// *not* widen the disk-driven whitelist (see `InstalledModels`): having
    /// large-v3 installed must not mean "Ghostie now listens for 99 languages".
    var multilingual: Bool = false

    /// Resolved absolute path under `~/.ghostie/models/`.
    var destPath: String { "\(Config.modelsDir)/\(filename)" }

    /// Sidecar path that stores `{etag, size, downloadedAt}` after a
    /// successful download. Doctor uses this to re-verify on demand.
    var sidecarPath: String { destPath + ".meta" }
}

enum Models {

    static let baseEnglish = Model(
        filename: "ggml-base.en.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!,
        label: "Whisper base (English) · ~150 MB",
        approxBytes: 147_964_211,
        language: "en",
        goodForLID: false   // English-only: cannot detect non-English audio
    )

    static let largeV3 = Model(
        filename: "ggml-large-v3-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin")!,
        label: "Whisper large-v3 (Q5) · ~1.1 GB",
        approxBytes: 1_081_140_203,
        language: "en",
        goodForLID: true,   // balanced multilingual — the LID/VAD driver of choice
        multilingual: true  // …and the default decoder for any language with no specialist
    )

    /// The lighter multilingual option: same 99 languages, roughly half the
    /// size and several times faster, at some accuracy cost. Offered alongside
    /// large-v3 for every language so a second or third language doesn't have
    /// to mean another gigabyte.
    static let largeV3Turbo = Model(
        filename: "ggml-large-v3-turbo-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo-q5_0.bin")!,
        label: "Whisper large-v3-turbo (Q5) · ~550 MB",
        approxBytes: 574_041_195,
        language: "en",
        goodForLID: true,
        multilingual: true
    )

    static let sileroVAD = Model(
        filename: "ggml-silero-v5.1.2.bin",
        url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
        label: "Silero VAD · ~900 KB",
        approxBytes: 885_098
    )

    /// Speaker embeddings for splitting the Participants track when more than
    /// one person shares the far end. WeSpeaker ResNet34-LM, trained on
    /// VoxCeleb and exported to ONNX by the sherpa-onnx project (Apache-2.0);
    /// `feats [1, T, 80] → embs [1, 256]`. Optional: without it Ghostie keeps
    /// today's single "Participants" label.
    static let speakerEmbedding = Model(
        filename: "wespeaker_en_voxceleb_resnet34_LM.onnx",
        url: URL(string: "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34_LM.onnx")!,
        label: "WeSpeaker ResNet34 speaker embeddings · ~27 MB",
        approxBytes: 26_530_550
    )

    /// KB-Whisper has multiple variants on different Hugging Face revisions.
    /// `subtitle` is HF-format only (no prebuilt GGML) and returns nil.
    static func kbWhisperLarge(variant: String) -> Model? {
        let rev: String
        switch variant {
        case "standard": rev = "main"
        case "strict":   rev = "strict"
        default:         return nil
        }
        return Model(
            filename: "ggml-kb-whisper-large-\(variant)-q5_0.bin",
            url: URL(string: "https://huggingface.co/KBLab/kb-whisper-large/resolve/\(rev)/ggml-model-q5_0.bin")!,
            label: "KB-Whisper-large (\(variant)) · ~1.1 GB",
            approxBytes: 1_081_140_203,
            language: "sv",
            goodForLID: false   // Swedish-biased language head — not a balanced LID
        )
    }

    /// The set of models Ghostie actually needs given the current config.
    /// Drives "Download missing models", the doctor row list, and the headless
    /// `fetch-models` subcommand.
    ///
    /// v3: derived from the **configured languages**, one model each, rather
    /// than a hardcoded sv+en pair. Pre-v3 any 2-language setup reported
    /// KB-Whisper + large-v3 as required, so a user running German+English got
    /// Settings popped open on launch auto-downloading 1.1 GB of Swedish.
    ///
    /// The balanced multilingual model that drives *language detection* is
    /// deliberately NOT required here: it's surfaced as a warning in Settings
    /// (see `LanguageSetup.Warning.noDetectionModel`) so it can't turn into a
    /// launch-time nag for a setup that otherwise transcribes fine.
    static func required(for config: Config) -> [Model] {
        required(for: config, catalog: ModelCatalog.load(),
                 installed: installed(preferredKBVariant: config.codeSwitch.kbWhisperVariant))
    }

    /// Catalog-injectable core of `required`, for unit tests.
    static func required(for config: Config, catalog: [CatalogEntry],
                         installed: InstalledModels) -> [Model] {
        let cs = config.codeSwitch
        // Configured languages are the user's stated intent; with none
        // configured the disk is the whitelist, exactly as at runtime.
        let codes = cs.languages.isEmpty ? installed.languages : cs.languages.map(\.code)

        var out: [Model] = []
        var seen = Set<String>()
        func add(_ m: Model?) {
            guard let m, seen.insert(m.filename).inserted else { return }
            out.append(m)
        }
        for code in codes {
            // An explicit model reference wins (it's what the pipeline will
            // load); otherwise the catalog's best entry for that language.
            let explicit = CodeSwitchConfig.resolveModelReference(
                cs.setting(for: code)?.model ?? "", kbVariant: cs.kbWhisperVariant)
            if !explicit.isEmpty,
               let entry = catalog.first(where: { $0.model()?.destPath == explicit }) {
                add(entry.model())
            } else {
                add(ModelCatalog.recommended(for: code, in: catalog,
                                             kbVariant: cs.kbWhisperVariant)?.model())
            }
        }
        // Nothing configured and nothing installed: a fresh install still needs
        // *a* speech model, and base.en is the small one we bootstrap with.
        if out.isEmpty { add(baseEnglish) }
        // VAD is optional for one language (doctor flags it as recommended) and
        // load-bearing for code-switching — required either way, it's ~900 KB.
        add(sileroVAD)
        // Speaker embeddings, so a call with three people on the far end comes
        // out labelled per speaker rather than as one "Participants". ~27 MB
        // against a speech model measured in hundreds, and fetching it here is
        // what makes diarization work on a fresh install instead of being a
        // flag the user has to find.
        if config.diarization { add(speakerEmbedding) }
        return out
    }

    /// Best model for the **single-language** path. Preference is catalog-driven
    /// and shaped by `quality` (`config.transcriptionQuality`):
    /// - `"best"` (default) reproduces the built-in order (large-v3 → KB →
    ///   base.en): a balanced multilingual model (`goodForLID`, e.g. large-v3)
    ///   first, then the largest specialist, with the small English-only floor
    ///   last. A custom multilingual model the user flagged `goodForLID`
    ///   becomes a candidate too.
    /// - `"balanced"` is the mirror image: a smaller specialist (base.en tier)
    ///   first, the multilingual heavyweights last — so a plain-English call
    ///   skips the 1.1 GB large-v3 load even when the code-switch pair is
    ///   installed.
    /// This keeps single-language transcription disk-driven like the code-switch
    /// path — best installed model, no config edit. `present` is the existence
    /// test — split out so the ordering is unit-testable without touching disk.
    static func bestSingleLanguageModel(quality: String = "best",
                                        present: (String) -> Bool) -> String? {
        bestSingleLanguageModel(from: ModelCatalog.load(), quality: quality, present: present)
    }

    /// Catalog-injectable core of `bestSingleLanguageModel`, for unit tests.
    /// Single-`Int64` rank (cheap to type-check): for `"best"` a `goodForLID`
    /// band first, then larger size — the (goodForLID, -size) order; for
    /// `"balanced"` both terms flip, so smaller non-`goodForLID` models win
    /// and large-v3 is only the fallback when nothing lighter is installed.
    /// An unknown `quality` value behaves as `"best"`.
    static func bestSingleLanguageModel(from entries: [CatalogEntry],
                                        quality: String = "best",
                                        present: (String) -> Bool) -> String? {
        func rank(_ e: CatalogEntry) -> Int64 {
            quality == "balanced"
                ? (e.goodForLID ? 1_000_000_000_000 : 0) + e.approxBytes
                : (e.goodForLID ? 0 : 1_000_000_000_000) - e.approxBytes
        }
        let sorted = entries.filter { !$0.language.isEmpty }.sorted { rank($0) < rank($1) }
        for e in sorted {
            guard let m = e.model() else { continue }
            if present(m.destPath) { return m.destPath }
        }
        return nil
    }

    /// Disk-backed `bestSingleLanguageModel`. nil when nothing is installed.
    static func bestSingleLanguageModelPath(quality: String = "best") -> String? {
        bestSingleLanguageModel(quality: quality) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    /// Every decode model the catalog knows about (built-ins + custom), for
    /// capability lookups. VAD and any other empty-`language` entry is excluded
    /// — it's not a decode target.
    static var allDecodeModels: [Model] { decodeModels(from: ModelCatalog.load()) }

    /// Catalog-injectable core of `allDecodeModels`, for unit tests.
    static func decodeModels(from entries: [CatalogEntry]) -> [Model] {
        entries.compactMap { $0.model() }.filter { !$0.language.isEmpty }
    }

    /// True when `path` is a *known* model that cannot drive language
    /// detection / VAD (KB-Whisper's Swedish-biased head, English-only
    /// base.en, or a custom specialist the user did NOT flag for detection).
    /// Unknown paths — and any catalog model flagged `goodForLID` — get the
    /// benefit of the doubt and return false so they remain eligible.
    static func isBadLIDDriver(path: String) -> Bool {
        isBadLIDDriver(path: path, in: allDecodeModels)
    }

    /// Catalog-injectable core of `isBadLIDDriver`, for unit tests.
    static func isBadLIDDriver(path: String, in models: [Model]) -> Bool {
        models.contains { !$0.goodForLID && $0.destPath == path }
    }

    /// What's currently on disk under `~/.ghostie/models/`, grouped by the
    /// language each model decodes (read from each catalog entry's `language`,
    /// so the language↔model map lives in `~/.ghostie/models.json` — adding an
    /// Arabic model is a catalog edit, not a source edit). Foundation of the v2
    /// code-switching pipeline: the **set of languages the pipeline is allowed
    /// to label audio with is whatever this returns** — no "configured for sv
    /// but no Swedish model installed" failure mode.
    ///
    /// `preferredKBVariant` (and, more generally, the sort below) decides which
    /// file represents a language when more than one is on disk: the configured
    /// KB variant first, then a balanced multilingual model, then by size. So a
    /// user who selected `strict` isn't silently decoded with `standard`. First
    /// existing file per language wins.
    static func installed(preferredKBVariant variant: String = "standard") -> InstalledModels {
        installed(from: ModelCatalog.load(), preferredKBVariant: variant) {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    /// Order two same-language catalog entries: configured KB variant first,
    /// then a balanced multilingual (`goodForLID`) model, then by descending
    /// size. Single-`Int64` rank with disjoint bands (cheap to type-check).
    ///
    /// Shared with `ModelCatalog.entries(for:)` so the model Settings *offers*
    /// for a language is the one `installed` would *pick* once it's on disk.
    static func siblingRank(_ e: CatalogEntry, preferredKBVariant variant: String) -> Int64 {
        let variantBand: Int64 = (e.kbVariant == variant) ? 0 : 4_000_000_000_000
        let lidBand: Int64 = e.goodForLID ? 0 : 2_000_000_000_000
        return variantBand + lidBand - e.approxBytes
    }

    /// Catalog-injectable core of `installed`, for unit tests. `present` is the
    /// on-disk existence test.
    static func installed(from entries: [CatalogEntry],
                          preferredKBVariant variant: String,
                          present: (String) -> Bool) -> InstalledModels {
        let ordered = entries.sorted {
            siblingRank($0, preferredKBVariant: variant) < siblingRank($1, preferredKBVariant: variant)
        }
        var perLanguage: [String: String] = [:]
        var multilingual: [String] = []
        for e in ordered where !e.language.isEmpty {
            guard let m = e.model(), present(m.destPath) else { continue }
            if perLanguage[e.language] == nil { perLanguage[e.language] = m.destPath }
            if e.multilingual { multilingual.append(m.destPath) }
        }
        return InstalledModels(perLanguage: perLanguage, multilingualPaths: multilingual)
    }
}

/// A read-only view of "which whisper models are available on this machine,
/// grouped by language". The v2 code-switching pipeline lifts its language
/// whitelist directly from `languages`; removing a model removes the language
/// with no config edit needed.
struct InstalledModels {
    /// language code → absolute GGML path, for models that *specialize* in that
    /// language. Empty == no whisper model on disk.
    let perLanguage: [String: String]

    /// Installed multilingual models (best first) — the fallback decoder for a
    /// language nothing specializes in. Kept separate from `perLanguage` on
    /// purpose: these must not widen `languages`.
    let multilingualPaths: [String]

    init(perLanguage: [String: String], multilingualPaths: [String] = []) {
        self.perLanguage = perLanguage
        self.multilingualPaths = multilingualPaths
    }

    /// The **disk-driven whitelist**: languages this install is set up for when
    /// the user hasn't configured any. Deliberately only the specialists —
    /// a multilingual model can decode ~99 languages, but installing one must
    /// not mean Ghostie starts listening for all of them. Sorted for stable
    /// doctor / log output.
    var languages: [String] { perLanguage.keys.sorted() }

    /// GGML path for a model that *specializes* in `lang`, or nil.
    func modelPath(for lang: String) -> String? { perLanguage[lang] }

    /// GGML path that can actually decode `lang`: its specialist if there is
    /// one, else the best installed multilingual model. This is what answers
    /// "can Ghostie handle German?" once the user has explicitly asked for
    /// German — usually yes, with the large-v3 they already have.
    func decodePath(for lang: String) -> String? {
        perLanguage[lang] ?? multilingualPaths.first
    }
}

/// What we last knew about a successfully-downloaded model. Lives next to the
/// model as JSON (`<filename>.meta`). Doctor reads this; downloader writes it.
struct ModelSidecar: Codable {
    let etag: String        // SHA256 from Hugging Face's `x-linked-etag` header
    let size: Int64         // byte count at the time of the successful download
    let downloadedAt: Date

    static func read(_ path: String) -> ModelSidecar? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder.iso.decode(ModelSidecar.self, from: data)
    }

    func write(to path: String) {
        guard let data = try? JSONEncoder.iso.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
