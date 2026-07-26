import Foundation

/// A user-extensible catalog of whisper models, each paired with a language.
///
/// This is what makes "bring your own model" work: instead of the supported
/// languages being a hardcoded list in `Models`, the catalog at
/// `~/.ghostie/models.json` declares every model Ghostie knows about — the
/// curated built-ins (large-v3, KB-Whisper, base.en, Silero VAD) plus anything
/// the user adds from Hugging Face. `Models.installed()` / `allDecodeModels` /
/// `bestSingleLanguageModel` all read this, so dropping in an Arabic model and
/// tagging it `language: "ar"` is enough for the pipeline to route Arabic audio
/// to it — no source edit.
///
/// The catalog stores **no absolute paths**: `Model.destPath`/`sidecarPath`
/// derive from `filename` under `~/.ghostie/models/`, which preserves the
/// `.dmg` self-heal property (paths re-resolve per machine).
struct CatalogEntry: Codable {
    /// On-disk filename under `~/.ghostie/models/`. Also the de-dup key and the
    /// key `ModelDownloader` / the sidecar use, so it must be unique.
    var filename: String
    /// Full Hugging Face `resolve/` URL. Stored as a String (URLs in JSON are
    /// fragile) and converted to `URL` in `model()`.
    var url: String
    var label: String
    /// The language this model decodes best (ISO code). Empty for VAD / models
    /// that aren't a decode target — those are excluded from language grouping.
    var language: String = ""
    /// Whether this is a *balanced multilingual* model fit to drive VAD and the
    /// `--detect-language` head (large-v3 = true; KB-Whisper's sv-biased head
    /// and English-only base.en = false). The "this model can tell languages
    /// apart" checkbox in the Add-a-language sheet writes this.
    var goodForLID: Bool = false
    /// Whether this model can *decode* any Whisper language rather than just
    /// `language`. Lets one large-v3 be the offered default for German,
    /// Spanish, and everything else without a per-language catalog entry.
    /// Distinct from `goodForLID`, which is about the language *head*: a model
    /// could decode many languages while being useless at identifying them.
    var multilingual: Bool = false
    /// Size hint for the UI / download skip-check. 0 == unknown (the downloader
    /// then relies on the sidecar, which is correct — never a false skip).
    var approxBytes: Int64 = 0
    /// True for the curated seed entries. Lets the UI forbid deleting them and
    /// keeps re-seeding idempotent; built-in url/size/language are always
    /// regenerated from code in `ModelCatalog.merge`, so they can't drift.
    var builtin: Bool = false
    /// KB-Whisper variant ("standard"/"strict") for the built-in KB seeds, so
    /// `Models.installed(preferredKBVariant:)` can order same-language siblings
    /// without re-introducing KB-specific branching. nil for everything else.
    var kbVariant: String?

    init(filename: String,
         url: String,
         label: String,
         language: String = "",
         goodForLID: Bool = false,
         multilingual: Bool = false,
         approxBytes: Int64 = 0,
         builtin: Bool = false,
         kbVariant: String? = nil) {
        self.filename = filename
        self.url = url
        self.label = label
        self.language = language
        self.goodForLID = goodForLID
        self.multilingual = multilingual
        self.approxBytes = approxBytes
        self.builtin = builtin
        self.kbVariant = kbVariant
    }

    /// Whether this entry can decode `code`: it either specializes in that
    /// language, or it's a multilingual model and the language is one Whisper
    /// knows. VAD (empty `language`) decodes nothing.
    func decodes(_ code: String) -> Bool {
        guard !language.isEmpty else { return false }
        if language == code { return true }
        return multilingual && WhisperLanguages.isSupported(code)
    }

    /// Build a seed entry from one of the built-in `Models` statics, so URLs /
    /// sizes / goodForLID flow from a single source of truth.
    init(from model: Model, builtin: Bool, kbVariant: String? = nil) {
        self.init(filename: model.filename,
                  url: model.url.absoluteString,
                  label: model.label,
                  language: model.language,
                  goodForLID: model.goodForLID,
                  multilingual: model.multilingual,
                  approxBytes: model.approxBytes,
                  builtin: builtin,
                  kbVariant: kbVariant)
    }

    /// The runtime `Model`, or nil when `url` doesn't parse (a hand-edited
    /// catalog typo) — callers `compactMap` so a bad row is skipped, not fatal.
    func model() -> Model? {
        guard let u = URL(string: url) else { return nil }
        return Model(filename: filename,
                     url: u,
                     label: label,
                     approxBytes: approxBytes,
                     language: language,
                     goodForLID: goodForLID,
                     multilingual: multilingual)
    }

    enum CodingKeys: String, CodingKey {
        case filename, url, label, language, goodForLID, multilingual
        case approxBytes, builtin, kbVariant
    }

    /// Hand-rolled to be resilient to missing keys (same trap that bit
    /// `Config`: synthesized `Decodable` throws on any absent key, which would
    /// drop a whole sparse hand-edited entry). `decodeIfPresent ?? default`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func g<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            do { if let v = try c.decodeIfPresent(T.self, forKey: k) { return v } } catch {}
            return fallback
        }
        filename = g(.filename, "")
        url = g(.url, "")
        label = g(.label, "")
        language = g(.language, "")
        goodForLID = g(.goodForLID, false)
        multilingual = g(.multilingual, false)
        approxBytes = g(.approxBytes, Int64(0))
        builtin = g(.builtin, false)
        kbVariant = (try? c.decodeIfPresent(String.self, forKey: .kbVariant)) ?? nil
    }
}

/// On-disk shape: `{ "models": [ … ] }` rather than a bare array, so a future
/// `schemaVersion` field can be added without breaking the decoder.
private struct CatalogFile: Codable {
    var models: [CatalogEntry] = []
    init(models: [CatalogEntry]) { self.models = models }
    enum CodingKeys: String, CodingKey { case models }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        models = ((try? c.decodeIfPresent([CatalogEntry].self, forKey: .models)) ?? nil) ?? []
    }
}

enum ModelCatalog {

    static var path: String { "\(NSHomeDirectory())/.ghostie/models.json" }

    /// The curated built-ins, derived from the `Models` statics. large-v3 first
    /// (the multilingual LID driver and the default decoder for any language
    /// without a specialist), then turbo (the lighter multilingual option),
    /// both KB variants, base.en, then VAD.
    static func builtinSeeds() -> [CatalogEntry] {
        var out: [CatalogEntry] = [
            CatalogEntry(from: Models.largeV3, builtin: true),
            CatalogEntry(from: Models.largeV3Turbo, builtin: true)
        ]
        for v in ["standard", "strict"] {
            if let kb = Models.kbWhisperLarge(variant: v) {
                out.append(CatalogEntry(from: kb, builtin: true, kbVariant: v))
            }
        }
        out.append(CatalogEntry(from: Models.baseEnglish, builtin: true))
        out.append(CatalogEntry(from: Models.sileroVAD, builtin: true))
        return out
    }

    /// The full catalog: built-in seeds (authoritative for url/size/language)
    /// merged with the user's `models.json` (custom entries + any goodForLID
    /// re-flag on a built-in). Falls back to seeds alone when the file is
    /// absent (first run) or unparseable (corrupt-file safety net).
    static func load() -> [CatalogEntry] {
        let seeds = builtinSeeds()
        guard let data = FileManager.default.contents(atPath: path),
              let file = try? JSONDecoder().decode(CatalogFile.self, from: data) else {
            return seeds
        }
        return merge(seeds: seeds, user: file.models)
    }

    /// Pure merge (no disk) so it's unit-testable. Built-ins stay authoritative
    /// for url/language/size/label — a sparse hand edit can only toggle a
    /// built-in's `goodForLID`, never corrupt its URL. User-only filenames are
    /// appended (first occurrence wins on a duplicate).
    static func merge(seeds: [CatalogEntry], user: [CatalogEntry]) -> [CatalogEntry] {
        let seedNames = Set(seeds.map { $0.filename })
        let userByName = Dictionary(user.map { ($0.filename, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [CatalogEntry] = seeds.map { seed in
            var s = seed
            if let u = userByName[seed.filename] { s.goodForLID = u.goodForLID }
            return s
        }
        var seen = seedNames
        for e in user where !seen.contains(e.filename) {
            out.append(e)
            seen.insert(e.filename)
        }
        return out
    }

    /// Every catalog entry that can decode `language`, best first — a
    /// specialist for that language, plus every multilingual model, so German
    /// and Spanish get a real default instead of "paste a Hugging Face repo".
    ///
    /// Ordering puts a **specialist ahead of a generalist** (KB-Whisper wins
    /// for Swedish even though large-v3 also decodes it), and otherwise reuses
    /// the ranking `Models.installed` applies to same-language siblings — so
    /// the model Settings *offers* is the one the pipeline would *choose* once
    /// it's on disk.
    static func entries(for language: String, in catalog: [CatalogEntry],
                        kbVariant: String) -> [CatalogEntry] {
        // Disjoint bands: `siblingRank` tops out around 6e12, so an 8e12
        // penalty on generalists can never be outweighed by it.
        func rank(_ e: CatalogEntry) -> Int64 {
            let generalistPenalty: Int64 = (e.language == language) ? 0 : 8_000_000_000_000
            return generalistPenalty + Models.siblingRank(e, preferredKBVariant: kbVariant)
        }
        return catalog.filter { $0.decodes(language) }.sorted { rank($0) < rank($1) }
    }

    /// The model Settings should offer to download for a language nobody has a
    /// model for yet. nil for a language the catalog knows nothing about — the
    /// UI then asks for a Hugging Face repo instead of inventing one.
    static func recommended(for language: String, in catalog: [CatalogEntry],
                            kbVariant: String) -> CatalogEntry? {
        entries(for: language, in: catalog, kbVariant: kbVariant).first
    }

    @discardableResult
    static func save(_ entries: [CatalogEntry]) -> Bool {
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(CatalogFile(models: entries)) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: path), options: .atomic)) != nil
    }

    /// First-run seeding. Writes the seeds only when `models.json` is absent —
    /// never overwrites a user file, or custom entries would vanish. Called
    /// next to `Config.writeExampleIfMissing()` in `main.swift`.
    static func seedIfMissing() {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        save(builtinSeeds())
    }

    /// Append or replace a catalog entry (by filename) and persist. Used by the
    /// Settings "Add a model" form.
    static func add(_ entry: CatalogEntry) {
        var entries = load()
        if let i = entries.firstIndex(where: { $0.filename == entry.filename }) {
            entries[i] = entry
        } else {
            entries.append(entry)
        }
        save(entries)
    }

    /// Remove a custom entry. Built-in filenames re-appear on the next `load()`
    /// (seeds are always merged in), so this only sticks for user-added models.
    static func remove(filename: String) {
        save(load().filter { $0.filename != filename })
    }
}

/// Turns whatever a user pastes into the "Add a model" form into a downloadable
/// file URL. The point is that pasting *just the repo* (`org/name`) works:
/// `resolve` queries the Hugging Face API to find the GGML `.bin` in the repo.
/// It also accepts a full file URL or an explicit `org/name/path/file.bin`.
enum HuggingFace {
    struct Resolved { let url: String; let filename: String }

    /// Network: blocks the calling thread for the repo-only case, so call this
    /// OFF the main thread. Returns nil on any failure (bad input, no `.bin`
    /// found, network error) — the caller surfaces a friendly message.
    static func resolve(_ raw: String) -> Resolved? {
        let input = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return nil }

        if input.lowercased().hasPrefix("http") {
            // A direct file URL (already points at a file)…
            if let u = URL(string: input),
               input.contains("/resolve/") || input.lowercased().hasSuffix(".bin") {
                return Resolved(url: input, filename: u.lastPathComponent)
            }
            // …or a repo *page* URL like https://huggingface.co/org/name.
            if let id = repoId(fromPageURL: input) { return resolveRepo(id) }
            return nil
        }

        // No scheme: "org/name" or "org/name/sub/file.bin".
        let parts = input.split(separator: "/").map(String.init)
        if parts.count >= 3 {
            let repo = "\(parts[0])/\(parts[1])"
            let file = parts[2...].joined(separator: "/")
            return Resolved(url: "https://huggingface.co/\(repo)/resolve/main/\(file)",
                            filename: (file as NSString).lastPathComponent)
        }
        if parts.count == 2 { return resolveRepo(input) }
        return nil
    }

    private static func repoId(fromPageURL s: String) -> String? {
        guard let u = URL(string: s), u.host?.contains("huggingface.co") == true else { return nil }
        let comps = u.path.split(separator: "/").map(String.init)
        return comps.count >= 2 ? "\(comps[0])/\(comps[1])" : nil
    }

    private struct ModelInfo: Decodable {
        struct Sibling: Decodable { let rfilename: String }
        let siblings: [Sibling]?
    }

    /// Ask the HF API which files a repo holds and pick the GGML `.bin`: prefer
    /// a quantized ggml file, then any ggml file, then the first `.bin`.
    private static func resolveRepo(_ repo: String) -> Resolved? {
        guard let api = URL(string: "https://huggingface.co/api/models/\(repo)") else { return nil }
        var req = URLRequest(url: api)
        req.timeoutInterval = 15
        var payload: Data?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, _, _ in payload = d; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 16)
        guard let payload,
              let info = try? JSONDecoder().decode(ModelInfo.self, from: payload) else { return nil }
        let bins = (info.siblings ?? []).map { $0.rfilename }
            .filter { $0.lowercased().hasSuffix(".bin") }
        guard !bins.isEmpty else { return nil }
        let pick = bins.first { $0.lowercased().contains("ggml") && $0.lowercased().contains("q5") }
            ?? bins.first { $0.lowercased().contains("ggml") }
            ?? bins[0]
        return Resolved(url: "https://huggingface.co/\(repo)/resolve/main/\(pick)",
                        filename: (pick as NSString).lastPathComponent)
    }
}
