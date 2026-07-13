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

    /// Model passed to `claude -p --model`. An alias ("sonnet", "opus",
    /// "haiku") or a full id ("claude-sonnet-4-6"). Only used when
    /// `summaryProvider == "claude"`.
    var summaryModel: String = "claude-sonnet-4-6"

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
    /// Labels the smoother is allowed to emit. Nordic look-alikes (`no`, `da`)
    /// detected on short Swedish audio are mapped to `sv` (see Smoother).
    /// Empty (the default) means "use whatever is installed on disk" — see
    /// `effectiveLanguages(installed:)`, so the disk drives the whitelist and
    /// a fresh install doesn't claim to need the code-switch model pair. A
    /// non-empty list is both an explicit override layer (configured ∩
    /// installed) and the "I want code-switching" intent signal Settings
    /// writes (see `Models.required`).
    var languages: [String] = []

    /// Tiebreaker when neither the local detection nor the cross-track prior
    /// is decisive.
    var dominantLanguage: String = "en"

    /// Logical model per language. Resolved to a GGML path by `modelPath(for:)`.
    /// Point both at the same value for a disk-constrained single-model setup.
    var modelPerLanguage: [String: String] = [
        "sv": "kb-whisper-large",
        "en": "whisper-large-v3"
    ]

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

    /// Decoder prompt per language. The N-language replacement for the old
    /// `promptSv` / `promptEn` pair: each model gets a prompt in its own
    /// language with the domain terms it should bias toward. Old configs
    /// carrying `promptSv` / `promptEn` migrate cleanly on load (see
    /// `init(from:)`); they are no longer written back on save.
    var prompts: [String: String] = [
        "sv": "Affärssamtal på svenska. Termer: Ingka, Xplore, IKEA, IFB.",
        "en": "Business call in English. Terms: Ingka, Xplore, IKEA, IFB, MCP, ACP."
    ]

    // Same missing-key resilience as Config: a partial `codeSwitch` object
    // (e.g. just `{"enabled": true}`) decodes, with the rest taking defaults.
    init() {}

    enum CodingKeys: String, CodingKey {
        case languages, dominantLanguage, modelPerLanguage, kbWhisperVariant
        case smoothingWindowMe, smoothingWindowParticipants, minSwitchSegments
        case minSwitchMs, maxFillGapMs, runPaddingMs, silencePadMs, minDetectMs
        case maxDetectMs
        case lidWindowMs, lidHopMs, intraSegmentRefineMs
        case intraSegmentMarginThreshold, minDwellMs
        case crossTrackPriorStrength, priorLookbackMs, prompts
        case snapSearchMs, snapMinMs, snapEnergyDb
        case verifyMarginDb
        // Removed in v2: `enabled` (now derived from installed-model count;
        // see Pipeline.swift). Old configs with the key load cleanly — Swift's
        // JSON decoder ignores unknown keys.
    }

    /// Pre-v2 prompt keys folded into `prompts` on decode, never encoded back.
    private enum LegacyPromptKeys: String, CodingKey {
        case promptSv, promptEn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CodeSwitchConfig()
        func g<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            do { if let v = try c.decodeIfPresent(T.self, forKey: k) { return v } }
            catch {}
            return fallback
        }
        languages = g(.languages, d.languages)
        dominantLanguage = g(.dominantLanguage, d.dominantLanguage)
        modelPerLanguage = g(.modelPerLanguage, d.modelPerLanguage)
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

        // Prompts: start from the built-in defaults, overlay the legacy
        // promptSv / promptEn pair, then overlay the new `prompts` map last so
        // it wins. Overlaying (rather than replacing) means customizing one
        // language — `{"prompts":{"sv":"…"}}` — keeps the default domain
        // prompt for every other language instead of blanking it.
        prompts = d.prompts
        if let legacy = try? decoder.container(keyedBy: LegacyPromptKeys.self) {
            if let sv = (try? legacy.decodeIfPresent(String.self, forKey: .promptSv)) ?? nil {
                prompts["sv"] = sv
            }
            if let en = (try? legacy.decodeIfPresent(String.self, forKey: .promptEn)) ?? nil {
                prompts["en"] = en
            }
        }
        if let p = (try? c.decodeIfPresent([String: String].self, forKey: .prompts)) ?? nil {
            prompts.merge(p) { _, new in new }
        }
    }

    /// Resolve the logical model name for `lang` to a GGML file path. Defers
    /// to `Models` for the well-known names (single source of truth with
    /// `ModelDownloader`); falls back to legacy resolution for bare GGML
    /// filenames or absolute overrides.
    func modelPath(for lang: String) -> String {
        let raw = (modelPerLanguage[lang] ?? "").trimmingCharacters(in: .whitespaces)
        if raw.isEmpty { return "" }
        if raw.hasPrefix("/") { return raw }
        switch raw {
        case "kb-whisper-large":
            return Models.kbWhisperLarge(variant: kbWhisperVariant)?.destPath ?? ""
        case "whisper-large-v3":
            return Models.largeV3.destPath
        default:
            let dir = Config.modelsDir
            return raw.hasSuffix(".bin") ? "\(dir)/\(raw)" : "\(dir)/ggml-\(raw).bin"
        }
    }

    /// The model-fine-tuned prompt for `lang`. Returns "" when the language
    /// has no entry — pipeline treats that as "no `--prompt` arg" so an
    /// unconfigured language doesn't get nudged toward the wrong domain.
    /// (Pre-v2 this silently fell back to `promptEn` for every non-`sv` label,
    /// which gave a 3-language config the English prompt for its German runs.)
    func prompt(for lang: String) -> String {
        prompts[lang] ?? ""
    }

    /// Languages this run will actually label audio with, given what is on
    /// disk. If `languages` is configured (non-empty), keep it but drop
    /// entries with no installed model — a user can't transcribe a language
    /// whose model they haven't downloaded. If `languages` is empty,
    /// the configured whitelist is "whatever is installed", so the pipeline
    /// turns languages on/off purely by `~/.ghostie/models/` content.
    ///
    /// Returned languages are de-duplicated (a hand-edited `["sv","sv"]` must
    /// not reach the smoother, where it would trap `Dictionary(uniqueKeys…)`)
    /// and, when configured, in `languages` order, preserving the user's
    /// stated priority; when empty, in `installed.languages` (sorted) order.
    func effectiveLanguages(installed: InstalledModels) -> [String] {
        let base = languages.isEmpty
            ? installed.languages
            : languages.filter { installed.modelPath(for: $0) != nil }
        var seen = Set<String>()
        return base.filter { seen.insert($0).inserted }
    }

    /// `dominantLanguage` clamped to the effective whitelist. When the
    /// configured dominant has no installed model it would otherwise route
    /// off-whitelist runs into a bucket the decoder never visits (dropped
    /// audio) and skew the smoother's prior toward a language with zero mass;
    /// fall back to the first effective language so the tiebreak/prior always
    /// points at something the pipeline can actually decode.
    func effectiveDominant(installed: InstalledModels) -> String {
        let langs = effectiveLanguages(installed: installed)
        return langs.contains(dominantLanguage) ? dominantLanguage : (langs.first ?? dominantLanguage)
    }

    /// GGML path for `lang`, layering the explicit `modelPerLanguage` override
    /// (if it resolves on disk) over the installed-models map. Returns nil
    /// when neither source can serve a model for that language — the caller
    /// surfaces that as "missing model, run setup.sh --codeswitch".
    func effectiveModelPath(for lang: String, installed: InstalledModels) -> String? {
        let override = modelPath(for: lang)
        if !override.isEmpty, FileManager.default.fileExists(atPath: override) {
            return override
        }
        return installed.modelPath(for: lang)
    }
}
