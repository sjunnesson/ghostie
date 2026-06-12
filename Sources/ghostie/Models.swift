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
        goodForLID: true    // balanced multilingual — the LID/VAD driver of choice
    )

    static let sileroVAD = Model(
        filename: "ggml-silero-v5.1.2.bin",
        url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
        label: "Silero VAD · ~900 KB",
        approxBytes: 885_098
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
    static func required(for config: Config) -> [Model] {
        var out: [Model] = []
        // "Wants code-switching" is an *explicit* ≥2-language whitelist (the
        // intent Settings writes) OR ≥2 language models already on disk. The
        // default empty `languages` therefore bootstraps the single-language
        // baseline (base-english), not the ~2GB code-switch pair — a fresh
        // install no longer auto-downloads KB+large-v3 it was never asked for.
        // A user who already has both models installed (effective ≥2) still
        // sees the pair as required rather than a spurious base-english.
        let cs = config.codeSwitch
        let installed = installed(preferredKBVariant: cs.kbWhisperVariant)
        let wantsCodeSwitch = cs.languages.count >= 2
            || cs.effectiveLanguages(installed: installed).count >= 2
        if wantsCodeSwitch {
            if let kb = kbWhisperLarge(variant: cs.kbWhisperVariant) {
                out.append(kb)
            }
            out.append(largeV3)
            out.append(sileroVAD)
        } else {
            out.append(baseEnglish)
            out.append(sileroVAD)   // optional but recommended; doctor flags it as such
        }
        return out
    }

    /// Best model for the **single-language** path. Preference is catalog-driven
    /// and reproduces the built-in order (large-v3 → KB → base.en): a balanced
    /// multilingual model (`goodForLID`, e.g. large-v3) first, then the largest
    /// specialist, with the small English-only floor last. A custom multilingual
    /// model the user flagged `goodForLID` becomes a candidate too. This keeps
    /// single-language transcription disk-driven like the code-switch path —
    /// best installed model, no config edit. `present` is the existence test —
    /// split out so the ordering is unit-testable without touching disk.
    static func bestSingleLanguageModel(present: (String) -> Bool) -> String? {
        bestSingleLanguageModel(from: ModelCatalog.load(), present: present)
    }

    /// Catalog-injectable core of `bestSingleLanguageModel`, for unit tests.
    /// Single-`Int64` rank (cheap to type-check): a `goodForLID` band first,
    /// then larger size — the (goodForLID, -size) order.
    static func bestSingleLanguageModel(from entries: [CatalogEntry],
                                        present: (String) -> Bool) -> String? {
        func rank(_ e: CatalogEntry) -> Int64 {
            (e.goodForLID ? 0 : 1_000_000_000_000) - e.approxBytes
        }
        let sorted = entries.filter { !$0.language.isEmpty }.sorted { rank($0) < rank($1) }
        for e in sorted {
            guard let m = e.model() else { continue }
            if present(m.destPath) { return m.destPath }
        }
        return nil
    }

    /// Disk-backed `bestSingleLanguageModel`. nil when nothing is installed.
    static func bestSingleLanguageModelPath() -> String? {
        bestSingleLanguageModel {
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

    /// Catalog-injectable core of `installed`, for unit tests. `present` is the
    /// on-disk existence test.
    static func installed(from entries: [CatalogEntry],
                          preferredKBVariant variant: String,
                          present: (String) -> Bool) -> InstalledModels {
        // Within a language, order siblings: configured KB variant first, then a
        // balanced multilingual (goodForLID) model, then by descending size.
        // Single-`Int64` rank with disjoint bands (cheap to type-check).
        func rank(_ e: CatalogEntry) -> Int64 {
            let variantBand: Int64 = (e.kbVariant == variant) ? 0 : 4_000_000_000_000
            let lidBand: Int64 = e.goodForLID ? 0 : 2_000_000_000_000
            return variantBand + lidBand - e.approxBytes
        }
        let ordered = entries.sorted { rank($0) < rank($1) }
        var perLanguage: [String: String] = [:]
        for e in ordered where !e.language.isEmpty && perLanguage[e.language] == nil {
            guard let m = e.model() else { continue }
            if present(m.destPath) { perLanguage[e.language] = m.destPath }
        }
        return InstalledModels(perLanguage: perLanguage)
    }
}

/// A read-only view of "which whisper models are available on this machine,
/// grouped by language". The v2 code-switching pipeline lifts its language
/// whitelist directly from `languages`; removing a model removes the language
/// with no config edit needed.
struct InstalledModels {
    /// language code → absolute GGML path. Empty == no whisper model on disk.
    let perLanguage: [String: String]

    /// Languages this install can decode. Sorted for stable doctor / log output.
    var languages: [String] { perLanguage.keys.sorted() }

    /// GGML path for `lang`, or nil if no model for that language is on disk.
    func modelPath(for lang: String) -> String? { perLanguage[lang] }
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
