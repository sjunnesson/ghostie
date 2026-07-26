import Foundation

/// User-tunable configuration. Loaded from ~/.ghostie/config.json if present,
/// otherwise sensible defaults are used. Environment variables override the file.
struct Config: Codable {

    // MARK: Output

    /// Folder where the final markdown summaries (and transcripts) are written.
    var notesFolder: String = "\(NSHomeDirectory())/Documents/Teams Call Notes"

    /// Keep the raw audio WAV files after processing (useful for debugging).
    var keepAudio: Bool = false

    /// Also write the raw merged transcript as a separate .md file.
    var saveTranscript: Bool = true

    // MARK: Detection

    /// Bundle-identifier prefixes that, when running, qualify a microphone
    /// session as a "Teams call". New Teams = com.microsoft.teams2,
    /// classic Teams = com.microsoft.teams.
    ///
    /// Deprecated: superseded by `triggerBundleIds`. Left readable for one
    /// release so existing user configs do not need editing. A non-default
    /// value triggers a warning log when the detector starts.
    var triggerBundlePrefixes: [String] = ["com.microsoft.teams"]

    /// Exact bundle IDs of the Teams **main** apps. The detector queries AX
    /// against PIDs whose bundle ID matches this list exactly. Audio helper
    /// processes (e.g. `com.microsoft.teams2.helper`) are still picked up by
    /// CoreAudio attribution via a prefix-with-dot match derived from these
    /// IDs, so a single list serves both purposes without cross-matching
    /// (classic Teams does not silently swallow new Teams helpers, or vice
    /// versa).
    var triggerBundleIds: [String] = ["com.microsoft.teams", "com.microsoft.teams2"]

    /// Opt-in, experimental: also detect Teams meetings held in a browser tab
    /// (teams.microsoft.com in Safari/Chrome/Edge/Arc). A browser's mic use
    /// only counts as a call signal while one of its windows shows a Teams
    /// meeting tab (AX title probe), so ordinary web-mic use never triggers a
    /// recording. Off by default: browser attribution is inherently weaker
    /// than the desktop app's per-PID signal — install the desktop client
    /// for anything you rely on.
    var detectBrowserTeams: Bool = false

    /// Browsers the tab probe may inspect when `detectBrowserTeams` is on.
    var browserBundleIds: [String] = [
        "com.apple.safari", "com.google.chrome",
        "com.microsoft.edgemac", "company.thebrowser.browser",
    ]

    /// Teams must continuously not be holding the mic for this long before a
    /// call is considered finished (rides over mute toggles, AirPods reconnects,
    /// brief Teams crashes). Matches the state-machine grace window in
    /// detector-rearchitecture.md.
    var endGraceSeconds: Double = 30.0

    /// Ignore "calls" shorter than this (avoids ringtones / accidental clicks).
    var minCallSeconds: Double = 20.0

    // MARK: Transcription (local, private — audio never leaves the machine)

    /// Path to the whisper.cpp CLI binary. Auto-detected if empty.
    var whisperBinary: String = ""

    /// Path to the whisper.cpp `whisper-server` binary. Auto-detected if
    /// empty, same resolution chain as `whisperBinary` (bundled .app copy →
    /// Homebrew/local paths). Used by the code-switching LID to keep one
    /// resident model loaded per call instead of reloading it per segment;
    /// absent is fine — the LID falls back to spawn-per-segment whisper-cli.
    var whisperServerBinary: String = ""

    /// Path to the ggml whisper model file.
    var whisperModel: String = "\(NSHomeDirectory())/.ghostie/models/ggml-base.en.bin"

    /// Spoken language. "auto" lets whisper detect it.
    var language: String = "en"

    /// Initial prompt biasing whisper toward clean, punctuated business
    /// speech (also nudges it away from silence hallucinations). Empty = none.
    var initialPrompt: String =
        "The following is a professional Microsoft Teams business call with clear punctuation and capitalization."

    /// Optional ggml Silero VAD model path. When set and present, whisper runs
    /// with Voice Activity Detection — the single biggest reducer of
    /// silence-driven hallucination. Empty = disabled. See scripts/setup.sh.
    var vadModel: String = "\(NSHomeDirectory())/.ghostie/models/ggml-silero-v5.1.2.bin"

    /// Run the post-transcription hallucination guard (dedup loops, noise
    /// markers, training-data-leak phrases). Strongly recommended.
    var cleanTranscript: Bool = true

    /// Quality/speed trade-off for the single-language model auto-pick.
    /// `"best"` (the default) keeps the disk-driven order: the highest-quality
    /// installed model wins (large-v3 once it's downloaded). `"balanced"`
    /// prefers a smaller/faster installed model (base.en tier) even when
    /// large-v3 is on disk — for users who fetched the code-switch pair but
    /// don't want plain-English calls paying the 1.1 GB large-v3 decode.
    /// Ignored when `GHOSTIE_WHISPER_MODEL` or an explicit config model pins
    /// the path (see `load()`).
    var transcriptionQuality: String = "best"

    // MARK: Code-switching (sv ↔ en — see code-switching.md)

    /// Per-segment, per-language transcription for mixed-language calls.
    /// When `enabled` is false the single-language path above is used and
    /// nothing changes.
    var codeSwitch: CodeSwitchConfig = CodeSwitchConfig()

    // MARK: Summarization

    /// Which backend writes the meeting note. `"claude"` shells out to the
    /// Claude Code CLI (default, cloud — best quality). `"ollama"` posts to a
    /// local Ollama server so the transcript never leaves the machine. The
    /// chosen provider is honored strictly — failures backlog, they don't
    /// silently fall back to the other one.
    var summaryProvider: String = "claude"

    /// Model passed to `claude -p --model`. Only used when
    /// `summaryProvider == "claude"`.
    ///
    /// Defaults to the **alias** `"sonnet"`, not a pinned version: the CLI
    /// resolves an alias to the latest model in that tier, so a fresh install
    /// follows Anthropic's releases instead of freezing on whatever shipped
    /// with this build (and can't break when a pinned version is retired). A
    /// full id (`"claude-sonnet-5"`) still works and is what Settings writes
    /// when someone deliberately pins one. See `ClaudeModels`.
    var summaryModel: String = ClaudeModels.defaultModel

    /// Path to the `claude` binary. Auto-detected if empty. Summarization uses
    /// your existing Claude Code login (subscription/OAuth) — no API key.
    /// Only used when `summaryProvider == "claude"`.
    var claudeBinary: String = ""

    /// Base URL of the Ollama HTTP server. Default targets the standard local
    /// install; a LAN host is also fine (e.g. `http://mac-mini.local:11434`).
    /// Only used when `summaryProvider == "ollama"`.
    var ollamaUrl: String = "http://localhost:11434"

    /// Ollama model name as it appears in `ollama list` (e.g. `llama3.1:8b`).
    /// Empty by default so a fresh user is nudged into Settings to pick one
    /// rather than hitting a 404 mid-call. Only used when
    /// `summaryProvider == "ollama"`.
    var ollamaModel: String = ""

    /// Wall-clock cap on one summarization request, both providers. The 300 s
    /// default matches the old hardcoded watchdog; raise it for big local
    /// Ollama models on slow hardware. Clamped to >= 60 at use.
    var summaryTimeoutSeconds: Double = 300

    // MARK: Updates (in-app OTA — see Updater.swift)

    /// Check GitHub Releases on launch + ~daily and surface a newer version.
    var autoCheckUpdates: Bool = true

    /// Last successful update check (throttles the launch/daily checks).
    var lastUpdateCheck: Date = .distantPast

    /// Point the updater at a fork/fixture feed instead of the canonical
    /// GitHub Releases endpoint (testing). Empty/nil = canonical.
    var updateFeedOverride: String? = nil

    // MARK: Internal paths

    /// Working directory for in-progress recordings.
    var workDir: String = "\(NSHomeDirectory())/.ghostie/recordings"

    // MARK: Codable
    //
    // Swift's *synthesized* Decodable throws `keyNotFound` for any absent key
    // (property defaults are NOT consulted). With `loadRaw()`'s `try?` that
    // would silently reset the ENTIRE config to defaults the moment one new
    // key is added to a user's existing config.json. So decode every key with
    // `decodeIfPresent`, falling back to the default value — old configs (and
    // partial ones) load cleanly and only the missing keys take defaults.
    // Encoding stays synthesized via these CodingKeys (Settings writes all).

    init() {}

    enum CodingKeys: String, CodingKey {
        case notesFolder, keepAudio, saveTranscript, triggerBundlePrefixes
        case triggerBundleIds, detectBrowserTeams, browserBundleIds
        case endGraceSeconds, minCallSeconds
        case whisperBinary, whisperServerBinary, whisperModel, language
        case initialPrompt, vadModel
        case cleanTranscript, transcriptionQuality, codeSwitch
        case summaryProvider, summaryModel, claudeBinary, ollamaUrl, ollamaModel
        case summaryTimeoutSeconds
        case workDir
        case autoCheckUpdates, lastUpdateCheck, updateFeedOverride
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config()
        func g<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            do { if let v = try c.decodeIfPresent(T.self, forKey: k) { return v } }
            catch {}
            return fallback
        }
        notesFolder = g(.notesFolder, d.notesFolder)
        keepAudio = g(.keepAudio, d.keepAudio)
        saveTranscript = g(.saveTranscript, d.saveTranscript)
        triggerBundlePrefixes = g(.triggerBundlePrefixes, d.triggerBundlePrefixes)
        triggerBundleIds = g(.triggerBundleIds, d.triggerBundleIds)
        detectBrowserTeams = g(.detectBrowserTeams, d.detectBrowserTeams)
        browserBundleIds = g(.browserBundleIds, d.browserBundleIds)
        endGraceSeconds = g(.endGraceSeconds, d.endGraceSeconds)
        minCallSeconds = g(.minCallSeconds, d.minCallSeconds)
        whisperBinary = g(.whisperBinary, d.whisperBinary)
        whisperServerBinary = g(.whisperServerBinary, d.whisperServerBinary)
        whisperModel = g(.whisperModel, d.whisperModel)
        language = g(.language, d.language)
        initialPrompt = g(.initialPrompt, d.initialPrompt)
        vadModel = g(.vadModel, d.vadModel)
        cleanTranscript = g(.cleanTranscript, d.cleanTranscript)
        transcriptionQuality = g(.transcriptionQuality, d.transcriptionQuality)
        codeSwitch = g(.codeSwitch, d.codeSwitch)
        summaryProvider = g(.summaryProvider, d.summaryProvider)
        summaryModel = g(.summaryModel, d.summaryModel)
        claudeBinary = g(.claudeBinary, d.claudeBinary)
        ollamaUrl = g(.ollamaUrl, d.ollamaUrl)
        ollamaModel = g(.ollamaModel, d.ollamaModel)
        summaryTimeoutSeconds = g(.summaryTimeoutSeconds, d.summaryTimeoutSeconds)
        workDir = g(.workDir, d.workDir)
        autoCheckUpdates = g(.autoCheckUpdates, d.autoCheckUpdates)
        lastUpdateCheck = g(.lastUpdateCheck, d.lastUpdateCheck)
        updateFeedOverride = g(.updateFeedOverride, d.updateFeedOverride)
    }

    // MARK: Loading

    static let configPath = "\(NSHomeDirectory())/.ghostie/config.json"

    /// The on-disk config (or defaults) WITHOUT env / runtime overlays — the
    /// baseline the Settings window edits and saves, so env-derived values
    /// never get baked into the file.
    static func loadRaw() -> Config {
        var cfg = Config()
        if let data = FileManager.default.contents(atPath: configPath),
           let parsed = try? JSONDecoder().decode(Config.self, from: data) {
            cfg = parsed
        }
        return cfg
    }

    /// Persist this config to disk (pretty-printed, stable key order).
    @discardableResult
    func save() -> Bool {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let dir = (Config.configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? enc.encode(self) else { return false }
        return (try? data.write(to: URL(fileURLWithPath: Config.configPath))) != nil
    }

    static func load() -> Config {
        var cfg = loadRaw()
        // Environment overrides win (handy for launchd / one-off runs).
        let env = ProcessInfo.processInfo.environment
        if let f = env["GHOSTIE_NOTES_FOLDER"], !f.isEmpty { cfg.notesFolder = f }
        if let s = env["GHOSTIE_SUMMARY_MODEL"], !s.isEmpty { cfg.summaryModel = s }
        if let p = env["GHOSTIE_SUMMARY_PROVIDER"], !p.isEmpty { cfg.summaryProvider = p }
        if let u = env["GHOSTIE_OLLAMA_URL"], !u.isEmpty { cfg.ollamaUrl = u }
        if let m = env["GHOSTIE_OLLAMA_MODEL"], !m.isEmpty { cfg.ollamaModel = m }
        if let f = env["GHOSTIE_UPDATE_FEED"], !f.isEmpty { cfg.updateFeedOverride = f }
        // Whisper binary: a copy bundled in the .app (self-contained .dmg)
        // always wins; then a still-valid explicit override; then detection.
        // This also self-heals a config.json that pins a path which doesn't
        // exist on this Mac (e.g. a Homebrew path on a fresh machine).
        if let bundled = Config.bundledResource("whisper-cli"),
           FileManager.default.isExecutableFile(atPath: bundled) {
            cfg.whisperBinary = bundled
        } else if cfg.whisperBinary.isEmpty
               || !FileManager.default.isExecutableFile(atPath: cfg.whisperBinary) {
            cfg.whisperBinary = Config.findWhisperBinary()
        }
        // whisper-server: identical precedence to whisper-cli above. "" is a
        // valid outcome — the LID then uses the spawn-per-segment fallback.
        if let bundled = Config.bundledResource("whisper-server"),
           FileManager.default.isExecutableFile(atPath: bundled) {
            cfg.whisperServerBinary = bundled
        } else if cfg.whisperServerBinary.isEmpty
               || !FileManager.default.isExecutableFile(atPath: cfg.whisperServerBinary) {
            cfg.whisperServerBinary = Config.findWhisperServerBinary()
        }
        if cfg.claudeBinary.isEmpty
           || !FileManager.default.isExecutableFile(atPath: cfg.claudeBinary) {
            cfg.claudeBinary = Config.findClaudeBinary()
        }
        // Single-language model resolution, in precedence order:
        //   1. GHOSTIE_WHISPER_MODEL — an explicit pin, honored verbatim.
        //   2. A config.json model that points at a real file other than the
        //      default — the user (or a prior setup) deliberately chose it.
        //   3. The best installed model for `transcriptionQuality` ("best":
        //      large-v3 → KB → base.en; "balanced": base.en tier first), so
        //      the single-language path is disk-driven like the code-switch
        //      path and gets large-v3 quality once downloaded, with no edit.
        //   4. The bundled base.en (fresh self-contained install, nothing else).
        if let m = env["GHOSTIE_WHISPER_MODEL"], !m.isEmpty {
            cfg.whisperModel = m
        } else {
            let pinned = cfg.whisperModel != Config().whisperModel
                && FileManager.default.fileExists(atPath: cfg.whisperModel)
            if !pinned,
               let best = Models.bestSingleLanguageModelPath(quality: cfg.transcriptionQuality) {
                cfg.whisperModel = best
            }
            if !FileManager.default.fileExists(atPath: cfg.whisperModel),
               let m = Config.bundledResource("ggml-base.en.bin") {
                cfg.whisperModel = m
            }
        }
        if !FileManager.default.fileExists(atPath: cfg.vadModel),
           let v = Config.bundledResource("ggml-silero-v5.1.2.bin") {
            cfg.vadModel = v
        }
        return cfg
    }

    /// Cached `resolveClaudeBinary()` result for the process lifetime
    /// (nil = not resolved yet, "" = resolved to "not found"). The resolution
    /// can spawn a login shell, and `Config.load()` runs on every 10-minute
    /// backlog drain tick — without this cache an absent claude meant a
    /// `zsh -lc` spawn every 10 minutes forever. Guarded by a lock because
    /// `Config.load()` is called from the engine's queues, the backlog timer,
    /// and the main thread (Settings) concurrently.
    private static var cachedClaudeBinary: String?
    private static let claudeBinaryLock = NSLock()

    static func findClaudeBinary() -> String {
        claudeBinaryLock.lock()
        defer { claudeBinaryLock.unlock() }
        if let cached = cachedClaudeBinary {
            // A miss ("") stays a miss for the process lifetime; a hit is
            // trusted only while the file still exists, so an uninstalled /
            // moved claude triggers exactly one fresh resolution.
            if cached.isEmpty || FileManager.default.isExecutableFile(atPath: cached) {
                return cached
            }
        }
        let resolved = resolveClaudeBinary()
        cachedClaudeBinary = resolved
        return resolved
    }

    /// Uncached resolution: well-known install locations first, then a PATH
    /// lookup via `zsh -lc` — deliberately a *login* shell so the user's
    /// Homebrew/profile PATH is in effect.
    private static func resolveClaudeBinary() -> String {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/usr/bin/claude"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        // Fall back to a login-shell PATH lookup.
        let path = runProcess("/bin/zsh", ["-lc", "command -v claude"], stderrToNull: true)
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileManager.default.isExecutableFile(atPath: path) ? path : ""
    }

    /// A file shipped inside Ghostie.app/Contents/Resources (self-contained
    /// `.dmg` build), or nil for a from-source build.
    static func bundledResource(_ name: String) -> String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        let p = res.appendingPathComponent(name).path
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    static func findWhisperBinary() -> String {
        // Prefer the binary bundled in the .app (notarized .dmg install).
        if let bundled = bundledResource("whisper-cli"),
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
            "/opt/homebrew/bin/whisper-cpp",
            "/usr/local/bin/whisper-cpp",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return ""
    }

    /// `whisper-server` resolution, mirroring `findWhisperBinary`: bundled
    /// .app copy (self-contained .dmg) → known Homebrew/local paths → "".
    /// Never persisted, so it self-heals across machines like the others.
    static func findWhisperServerBinary() -> String {
        if let bundled = bundledResource("whisper-server"),
           FileManager.default.isExecutableFile(atPath: bundled) {
            return bundled
        }
        let candidates = [
            "/opt/homebrew/bin/whisper-server",
            "/usr/local/bin/whisper-server"
        ]
        for c in candidates where FileManager.default.isExecutableFile(atPath: c) {
            return c
        }
        return ""
    }

    /// Models directory shared by setup.sh and the code-switching resolver.
    static var modelsDir: String { "\(NSHomeDirectory())/.ghostie/models" }

    /// Scratch directory for downloaded OTA update payloads (see Updater).
    static var updatesDir: String { "\(NSHomeDirectory())/.ghostie/updates" }

    func writeExampleIfMissing() {
        let dir = (Config.configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: Config.configPath) else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        // Write pristine defaults — never persist auto-detected binary paths,
        // so resolution (incl. the bundled binary) re-runs on every machine.
        if let data = try? enc.encode(Config()) {
            try? data.write(to: URL(fileURLWithPath: Config.configPath))
        }
    }
}

/// Tunables for the Swedish↔English code-switching pipeline. Every field has a
/// safe default so an existing config.json (which has no `codeSwitch` key)
/// decodes unchanged — Swift's synthesized Decodable falls back to the default
/// when a key is absent, the same pattern the rest of Config relies on.
struct CodeSwitchConfig: Codable {
    /// The languages Ghostie is configured to understand, in priority order,
    /// each carrying its own model and prompt (see `LanguageSetting`).
    ///
    /// **Empty (the default) means "not configured — use whatever is installed
    /// on disk"**, so a fresh install doesn't claim to need a model pair nobody
    /// asked for and removing a model self-heals the whitelist. Settings
    /// materializes the full list the moment the user adds or removes a
    /// language, so from then on what the list says and what the pane shows are
    /// the same thing.
    ///
    /// v3: this replaces the three parallel maps that used to encode one
    /// concept — `languages: [String]`, `modelPerLanguage` and `prompts`. A
    /// pre-v3 `["sv","en"]` decodes straight into records (see
    /// `LanguageSetting.init(from:)`) and the two old maps are folded in below.
    var languages: [LanguageSetting] = []

    /// Tiebreaker when neither the local detection nor the cross-track prior
    /// is decisive.
    var dominantLanguage: String = "en"

    /// KB-Whisper Stage-2 variant used for Swedish: standard | subtitle | strict.
    var kbWhisperVariant: String = "standard"

    var smoothingWindowMe: Int = 4
    var smoothingWindowParticipants: Int = 4
    var minSwitchSegments: Int = 2

    /// A run of the opposite language switches the timeline if it spans either
    /// `minSwitchSegments` segments *or* this many milliseconds. The duration
    /// floor catches a genuine long switch that VAD happened to return as one
    /// segment (a real loanword is short in time, so it still won't switch).
    var minSwitchMs: Int = 2500
    var maxFillGapMs: Int = 4000
    var runPaddingMs: Int = 200
    var silencePadMs: Int = 500
    var minDetectMs: Int = 1500

    /// A VAD segment longer than this is split into equal chunks (each ≤ this,
    /// each > half of it) that are language-detected independently. Without
    /// the split, a switch *inside* one long segment is averaged into a single
    /// label — and the LID only ever saw the first 30 s anyway (its slice
    /// cap). Detection granularity only; the smoother + snap-to-silence still
    /// decide the decode boundaries. Clamped at use to ≥ 2×minDetectMs.
    var maxDetectMs: Int = 8000

    // Fine (sliding-window) LID pass — only runs under a low-latency
    // identifier (the ONNX VoxLingua107 LID); whisper-based LIDs at ~1.2 s
    // per window would multiply detect time by the window count.

    /// Sliding-window width for the fine LID pass inside long/ambiguous
    /// detect chunks.
    var lidWindowMs: Int = 1500
    /// Hop between consecutive fine-pass windows.
    var lidHopMs: Int = 500
    /// A detect chunk longer than this gets the fine pass (a switch could
    /// hide inside it).
    var intraSegmentRefineMs: Int = 4000
    /// A coarse detection whose top1−top2 log-prob margin is at or under
    /// this is ambiguous enough to warrant the fine pass regardless of
    /// length.
    var intraSegmentMarginThreshold: Double = 0.15
    /// A fine-pass language change must sustain itself this long to become a
    /// change point — half-second blips never break a sentence.
    var minDwellMs: Int = 1500

    /// 0.5 disables cross-track refinement (Pass 2 becomes a no-op); 1.0 makes
    /// the other track's recent language absolute. 0.75 flips ambiguous
    /// segments without overruling a confident local detection.
    var crossTrackPriorStrength: Double = 0.75
    var priorLookbackMs: Int = 8000

    // MARK: Snap-to-silence (PR 4)
    //
    // After smoothing, each language-switch boundary is moved to the nearest
    // real silence trough so the decoder doesn't cut a syllable in half. If
    // no trough is found in the search window, the two adjacent runs merge
    // into the dominant-length language rather than producing a mid-word cut.

    /// Window (± ms around the smoother boundary) within which we look for a
    /// silence trough. Larger windows catch wider word-boundary gaps; too
    /// large lets the cut wander far from the actual switch.
    var snapSearchMs: Int = 1500
    /// Minimum trough duration. Below this is normal phoneme energy dips, not
    /// a word boundary.
    var snapMinMs: Int = 80
    /// dBFS threshold. Per-frame RMS below this counts as silence.
    var snapEnergyDb: Double = -40

    // MARK: Post-decode re-LID verification (PR 5)

    /// Re-routing threshold. After snap-to-silence, each run's audio is
    /// re-checked by the LID at its post-snap boundaries (longer, cleaner
    /// audio than the original per-VAD-segment evidence). If the LID's
    /// top-1 language sits at least this much higher in log-prob than the
    /// originally-routed language, the run re-routes to the LID's pick
    /// and decodes against that language's model instead. 0 disables the
    /// check; 0.20 ≈ "LID at least exp(0.20) ≈ 1.22× more confident".
    ///
    /// Defaults to 0 (off): today's only identifier is `WhisperLID`, the same
    /// model that made the original routing decision, so re-asking it shares
    /// the very failure mode (Nordic/short-audio confusion) the pass is meant
    /// to catch and can re-route a correct run to the wrong model. Turn it on
    /// once a genuinely independent LID (VoxLingua107) backs the verifier.
    var verifyMarginDb: Double = 0

    // MARK: Legacy per-language maps (decoded, never encoded)
    //
    // Pre-v3 these were first-class config. They now exist only as a *fallback
    // layer* for an install whose `languages` list is still empty (i.e. the
    // user never configured anything but did hand-edit a prompt). The moment
    // Settings writes a `LanguageSetting`, that record carries the value and
    // these stop mattering; `save()` never writes them back.

    /// Pre-v3 `prompts` (and pre-v2 `promptSv`/`promptEn`), folded in on decode.
    private(set) var legacyPrompts: [String: String] = [:]
    /// Pre-v3 `modelPerLanguage`, folded in on decode.
    private(set) var legacyModelNames: [String: String] = [:]

    // Same missing-key resilience as Config: a partial `codeSwitch` object
    // (e.g. just `{"enabled": true}`) decodes, with the rest taking defaults.
    init() {}

    enum CodingKeys: String, CodingKey {
        case languages, dominantLanguage, kbWhisperVariant
        case smoothingWindowMe, smoothingWindowParticipants, minSwitchSegments
        case minSwitchMs, maxFillGapMs, runPaddingMs, silencePadMs, minDetectMs
        case maxDetectMs
        case lidWindowMs, lidHopMs, intraSegmentRefineMs
        case intraSegmentMarginThreshold, minDwellMs
        case crossTrackPriorStrength, priorLookbackMs
        case snapSearchMs, snapMinMs, snapEnergyDb
        case verifyMarginDb
        // Removed in v2: `enabled` (now derived from installed-model count;
        // see Pipeline.swift). Removed in v3: `prompts`, `modelPerLanguage`
        // (folded into `languages` records). Old configs carrying any of them
        // load cleanly — see `LegacyKeys` below.
    }

    /// Keys Ghostie still *reads* for back-compat but never writes again.
    private enum LegacyKeys: String, CodingKey {
        case promptSv, promptEn, prompts, modelPerLanguage
    }

    /// The pre-v3 `modelPerLanguage` *defaults*. Every existing config.json has
    /// these two entries whether or not the user chose them — they were shipped
    /// defaults that got persisted on first save. Migrating them as explicit
    /// pins would show "pinned" on two rows nobody pinned, and would freeze
    /// those languages onto one model forever. They resolve to exactly what the
    /// auto-pick produces anyway, so a value matching them migrates to nil; a
    /// genuine hand-edit still carries over.
    private static let preV3DefaultModels = ["sv": "kb-whisper-large",
                                             "en": "whisper-large-v3"]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CodeSwitchConfig()
        func g<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            do { if let v = try c.decodeIfPresent(T.self, forKey: k) { return v } }
            catch {}
            return fallback
        }
        dominantLanguage = g(.dominantLanguage, d.dominantLanguage)
        kbWhisperVariant = g(.kbWhisperVariant, d.kbWhisperVariant)
        smoothingWindowMe = g(.smoothingWindowMe, d.smoothingWindowMe)
        smoothingWindowParticipants = g(.smoothingWindowParticipants, d.smoothingWindowParticipants)
        minSwitchSegments = g(.minSwitchSegments, d.minSwitchSegments)
        minSwitchMs = g(.minSwitchMs, d.minSwitchMs)
        maxFillGapMs = g(.maxFillGapMs, d.maxFillGapMs)
        runPaddingMs = g(.runPaddingMs, d.runPaddingMs)
        silencePadMs = g(.silencePadMs, d.silencePadMs)
        minDetectMs = g(.minDetectMs, d.minDetectMs)
        maxDetectMs = g(.maxDetectMs, d.maxDetectMs)
        lidWindowMs = g(.lidWindowMs, d.lidWindowMs)
        lidHopMs = g(.lidHopMs, d.lidHopMs)
        intraSegmentRefineMs = g(.intraSegmentRefineMs, d.intraSegmentRefineMs)
        intraSegmentMarginThreshold = g(.intraSegmentMarginThreshold, d.intraSegmentMarginThreshold)
        minDwellMs = g(.minDwellMs, d.minDwellMs)
        crossTrackPriorStrength = g(.crossTrackPriorStrength, d.crossTrackPriorStrength)
        priorLookbackMs = g(.priorLookbackMs, d.priorLookbackMs)
        snapSearchMs = g(.snapSearchMs, d.snapSearchMs)
        snapMinMs = g(.snapMinMs, d.snapMinMs)
        snapEnergyDb = g(.snapEnergyDb, d.snapEnergyDb)
        verifyMarginDb = g(.verifyMarginDb, d.verifyMarginDb)

        // ---- v3 language records + migration -----------------------------
        //
        // `languages` decodes from BOTH shapes without a version field: the v3
        // array of objects, and the pre-v3 array of bare codes (see
        // `LanguageSetting.init(from:)`). The two old side-maps are then
        // overlaid onto whichever records exist, so a user who had
        // `{"languages":["sv","en"],"modelPerLanguage":{"sv":"kb-whisper-large"},
        //   "prompts":{"sv":"…"}}` comes out with two complete records and
        // loses nothing.
        if let legacy = try? decoder.container(keyedBy: LegacyKeys.self) {
            if let sv = (try? legacy.decodeIfPresent(String.self, forKey: .promptSv)) ?? nil {
                legacyPrompts["sv"] = sv
            }
            if let en = (try? legacy.decodeIfPresent(String.self, forKey: .promptEn)) ?? nil {
                legacyPrompts["en"] = en
            }
            // The v3-removed `prompts` map wins over the v2-removed pair.
            if let p = (try? legacy.decodeIfPresent([String: String].self, forKey: .prompts)) ?? nil {
                legacyPrompts.merge(p) { _, new in new }
            }
            if let m = (try? legacy.decodeIfPresent([String: String].self, forKey: .modelPerLanguage)) ?? nil {
                legacyModelNames = m
            }
        }
        let decoded = ((try? c.decodeIfPresent([LanguageSetting].self, forKey: .languages)) ?? nil) ?? []
        languages = decoded.compactMap { rec in
            guard !rec.code.isEmpty else { return nil }   // hand-edited junk row
            var r = rec
            if r.prompt == nil, let p = legacyPrompts[r.code] { r.prompt = p }
            if r.model == nil, let m = legacyModelNames[r.code],
               !m.trimmingCharacters(in: .whitespaces).isEmpty,
               m != Self.preV3DefaultModels[r.code] { r.model = m }
            return r
        }
    }

    // MARK: Per-language lookups
    //
    // Every one of these reads the `languages` records first and falls back to
    // the legacy maps only for an install that has never been configured. They
    // are the single seam between "what the user asked for" and "what the
    // pipeline does" — the segmenter, smoother, verifier and decoder all route
    // through them, so they must not diverge.

    /// The configured record for `lang`, if the user has one. First match wins
    /// (a hand-edited duplicate code can't produce two answers).
    func setting(for lang: String) -> LanguageSetting? {
        languages.first { $0.code == lang }
    }

    /// Resolve the model reference for `lang` to a GGML file path. The
    /// reference is normally a catalog filename; an absolute path and the
    /// pre-v3 logical names (`kb-whisper-large`, `whisper-large-v3`) still
    /// resolve so hand-edited and migrated configs keep working. "" when the
    /// language has no explicit model — the caller then falls back to the
    /// best installed model for that language.
    func modelPath(for lang: String) -> String {
        let raw = (setting(for: lang)?.model ?? legacyModelNames[lang] ?? "")
        return Self.resolveModelReference(raw, kbVariant: kbWhisperVariant)
    }

    /// Pure reference → path resolution, split out so it's testable and so the
    /// Settings model picker resolves exactly what the pipeline will.
    static func resolveModelReference(_ reference: String, kbVariant: String) -> String {
        let raw = reference.trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return "" }
        if raw.hasPrefix("/") { return raw }
        switch raw {
        case "kb-whisper-large":
            return Models.kbWhisperLarge(variant: kbVariant)?.destPath ?? ""
        case "whisper-large-v3":
            return Models.largeV3.destPath
        default:
            let dir = Config.modelsDir
            return raw.hasSuffix(".bin") ? "\(dir)/\(raw)" : "\(dir)/ggml-\(raw).bin"
        }
    }

    /// The model-fine-tuned prompt for `lang`: the record's prompt, else a
    /// legacy hand-edit, else the built-in default for that language, else ""
    /// — which the pipeline treats as "no `--prompt` arg" so an unconfigured
    /// language doesn't get nudged toward the wrong domain. (Pre-v2 this
    /// silently fell back to `promptEn` for every non-`sv` label, which gave a
    /// 3-language config the English prompt for its German runs.)
    func prompt(for lang: String) -> String {
        if let explicit = setting(for: lang)?.prompt { return explicit }
        if let legacy = legacyPrompts[lang] { return legacy }
        return LanguageDefaults.prompt(for: lang)
    }

    /// Languages this run will actually label audio with, given what is on
    /// disk. If `languages` is configured (non-empty), keep it but drop
    /// entries that resolve to no model — a user can't transcribe a language
    /// whose model they haven't downloaded. If `languages` is empty, the
    /// install has never been configured, so the whitelist is "whatever is
    /// installed" and the pipeline turns languages on/off purely by
    /// `~/.ghostie/models/` content.
    ///
    /// Returned languages are de-duplicated (a hand-edited `["sv","sv"]` must
    /// not reach the smoother, where it would trap `Dictionary(uniqueKeys…)`)
    /// and, when configured, in `languages` order, preserving the user's
    /// stated priority; when empty, in `installed.languages` (sorted) order.
    func effectiveLanguages(installed: InstalledModels,
                            present: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [String] {
        let base = languages.isEmpty
            ? installed.languages
            // Resolve through `effectiveModelPath`, not `installed` alone, so a
            // language served only by an explicit out-of-catalog model path
            // stays in the whitelist instead of being dropped here and then
            // resolved by the decoder — the two used to disagree.
            : languages.map(\.code).filter {
                effectiveModelPath(for: $0, installed: installed, present: present) != nil
              }
        var seen = Set<String>()
        return base.filter { seen.insert($0).inserted }
    }

    /// `dominantLanguage` clamped to the effective whitelist. When the
    /// configured dominant has no installed model it would otherwise route
    /// off-whitelist runs into a bucket the decoder never visits (dropped
    /// audio) and skew the smoother's prior toward a language with zero mass;
    /// fall back to the first effective language so the tiebreak/prior always
    /// points at something the pipeline can actually decode.
    func effectiveDominant(installed: InstalledModels,
                           present: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> String {
        let langs = effectiveLanguages(installed: installed, present: present)
        return langs.contains(dominantLanguage) ? dominantLanguage : (langs.first ?? dominantLanguage)
    }

    /// GGML path for `lang`: the record's explicit model when it resolves on
    /// disk, otherwise the best installed model that can decode that language —
    /// its specialist if one is installed, else an installed multilingual model
    /// (see `InstalledModels.decodePath`). That fallback is why adding German
    /// usually costs no download at all: the large-v3 already on disk for
    /// detection decodes it. Returns nil when nothing can serve it — Settings
    /// surfaces that as "no model", the CLI as "missing model, run setup.sh
    /// --codeswitch".
    ///
    /// `present` is the on-disk existence test, injectable so the pure
    /// `LanguageSetup` resolver (and its self-tests) can answer the same
    /// question without touching the filesystem.
    func effectiveModelPath(for lang: String, installed: InstalledModels,
                            present: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> String? {
        let explicit = modelPath(for: lang)
        if !explicit.isEmpty, present(explicit) { return explicit }
        return installed.decodePath(for: lang)
    }
}
