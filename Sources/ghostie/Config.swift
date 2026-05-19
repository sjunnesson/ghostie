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
    var triggerBundlePrefixes: [String] = ["com.microsoft.teams"]

    /// Require a trigger app (Teams) to be running for a call to be detected.
    /// If false, ANY microphone session is treated as a call.
    var requireTriggerApp: Bool = true

    /// How often to poll for call start/stop, in seconds.
    var pollIntervalSeconds: Double = 2.0

    /// The microphone must be continuously idle for this long before a call is
    /// considered finished (rides over short pauses / mute toggles).
    var endGraceSeconds: Double = 12.0

    /// Ignore "calls" shorter than this (avoids ringtones / accidental clicks).
    var minCallSeconds: Double = 20.0

    // MARK: Transcription (local, private — audio never leaves the machine)

    /// Path to the whisper.cpp CLI binary. Auto-detected if empty.
    var whisperBinary: String = ""

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

    // MARK: Code-switching (sv ↔ en — see code-switching.md)

    /// Per-segment, per-language transcription for mixed-language calls.
    /// When `enabled` is false the single-language path above is used and
    /// nothing changes.
    var codeSwitch: CodeSwitchConfig = CodeSwitchConfig()

    // MARK: Summarization (via the Claude Code CLI — no API key needed)

    /// Model passed to `claude -p --model`. An alias ("sonnet", "opus",
    /// "haiku") or a full id ("claude-sonnet-4-6").
    var summaryModel: String = "claude-sonnet-4-6"

    /// Path to the `claude` binary. Auto-detected if empty. Summarization uses
    /// your existing Claude Code login (subscription/OAuth) — no API key.
    var claudeBinary: String = ""

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
        case requireTriggerApp, pollIntervalSeconds, endGraceSeconds, minCallSeconds
        case whisperBinary, whisperModel, language, initialPrompt, vadModel
        case cleanTranscript, codeSwitch, summaryModel, claudeBinary, workDir
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
        requireTriggerApp = g(.requireTriggerApp, d.requireTriggerApp)
        pollIntervalSeconds = g(.pollIntervalSeconds, d.pollIntervalSeconds)
        endGraceSeconds = g(.endGraceSeconds, d.endGraceSeconds)
        minCallSeconds = g(.minCallSeconds, d.minCallSeconds)
        whisperBinary = g(.whisperBinary, d.whisperBinary)
        whisperModel = g(.whisperModel, d.whisperModel)
        language = g(.language, d.language)
        initialPrompt = g(.initialPrompt, d.initialPrompt)
        vadModel = g(.vadModel, d.vadModel)
        cleanTranscript = g(.cleanTranscript, d.cleanTranscript)
        codeSwitch = g(.codeSwitch, d.codeSwitch)
        summaryModel = g(.summaryModel, d.summaryModel)
        claudeBinary = g(.claudeBinary, d.claudeBinary)
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
        if let m = env["GHOSTIE_WHISPER_MODEL"], !m.isEmpty { cfg.whisperModel = m }
        if let s = env["GHOSTIE_SUMMARY_MODEL"], !s.isEmpty { cfg.summaryModel = s }
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
        if cfg.claudeBinary.isEmpty
           || !FileManager.default.isExecutableFile(atPath: cfg.claudeBinary) {
            cfg.claudeBinary = Config.findClaudeBinary()
        }
        // Fall back to models bundled in the .app when the configured paths
        // don't exist (fresh self-contained install with no Homebrew/setup).
        if !FileManager.default.fileExists(atPath: cfg.whisperModel),
           let m = Config.bundledResource("ggml-base.en.bin") {
            cfg.whisperModel = m
        }
        if !FileManager.default.fileExists(atPath: cfg.vadModel),
           let v = Config.bundledResource("ggml-silero-v5.1.2.bin") {
            cfg.vadModel = v
        }
        return cfg
    }

    static func findClaudeBinary() -> String {
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
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-lc", "command -v claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                          encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
    /// When false the single-language transcribe path is used and nothing
    /// about the pipeline changes.
    var enabled: Bool = false

    /// Labels the smoother is allowed to emit. Nordic look-alikes (`no`, `da`)
    /// detected on short Swedish audio are mapped to `sv` (see Smoother).
    var languages: [String] = ["sv", "en"]

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

    /// 0.5 disables cross-track refinement (Pass 2 becomes a no-op); 1.0 makes
    /// the other track's recent language absolute. 0.75 flips ambiguous
    /// segments without overruling a confident local detection.
    var crossTrackPriorStrength: Double = 0.75
    var priorLookbackMs: Int = 8000

    var promptSv: String = "Affärssamtal på svenska. Termer: Ingka, Xplore, IKEA, IFB."
    var promptEn: String = "Business call in English. Terms: Ingka, Xplore, IKEA, IFB, MCP, ACP."

    // Same missing-key resilience as Config: a partial `codeSwitch` object
    // (e.g. just `{"enabled": true}`) decodes, with the rest taking defaults.
    init() {}

    enum CodingKeys: String, CodingKey {
        case enabled, languages, dominantLanguage, modelPerLanguage, kbWhisperVariant
        case smoothingWindowMe, smoothingWindowParticipants, minSwitchSegments
        case minSwitchMs, maxFillGapMs, runPaddingMs, silencePadMs, minDetectMs
        case crossTrackPriorStrength, priorLookbackMs, promptSv, promptEn
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = CodeSwitchConfig()
        func g<T: Decodable>(_ k: CodingKeys, _ fallback: T) -> T {
            do { if let v = try c.decodeIfPresent(T.self, forKey: k) { return v } }
            catch {}
            return fallback
        }
        enabled = g(.enabled, d.enabled)
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
        crossTrackPriorStrength = g(.crossTrackPriorStrength, d.crossTrackPriorStrength)
        priorLookbackMs = g(.priorLookbackMs, d.priorLookbackMs)
        promptSv = g(.promptSv, d.promptSv)
        promptEn = g(.promptEn, d.promptEn)
    }

    /// Resolve the logical model name for `lang` to a GGML file path.
    /// An absolute path is used verbatim (advanced users); the well-known
    /// names map to setup.sh's on-disk filenames; a bare ggml name resolves
    /// under `~/.ghostie/models/`.
    func modelPath(for lang: String) -> String {
        let raw = (modelPerLanguage[lang] ?? "").trimmingCharacters(in: .whitespaces)
        if raw.hasPrefix("/") { return raw }
        let dir = Config.modelsDir
        switch raw {
        case "kb-whisper-large":
            return "\(dir)/ggml-kb-whisper-large-\(kbWhisperVariant)-q5_0.bin"
        case "whisper-large-v3":
            return "\(dir)/ggml-large-v3-q5_0.bin"
        case "":
            return ""
        default:
            return raw.hasSuffix(".bin") ? "\(dir)/\(raw)" : "\(dir)/ggml-\(raw).bin"
        }
    }

    /// The model-fine-tuned prompt for `lang` (KB-Whisper expects Swedish).
    func prompt(for lang: String) -> String {
        lang == "sv" ? promptSv : promptEn
    }

    /// Distinct GGML model paths actually needed, for doctor / preflight.
    var requiredModelPaths: [(lang: String, path: String)] {
        languages.map { ($0, modelPath(for: $0)) }
    }
}
