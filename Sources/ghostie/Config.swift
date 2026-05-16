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

    // MARK: Summarization

    /// Anthropic model used to analyse the transcript.
    var summaryModel: String = "claude-sonnet-4-6"

    /// API key. Prefer the ANTHROPIC_API_KEY environment variable.
    var anthropicApiKey: String = ""

    // MARK: Internal paths

    /// Working directory for in-progress recordings.
    var workDir: String = "\(NSHomeDirectory())/.ghostie/recordings"

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
        if let k = env["ANTHROPIC_API_KEY"], !k.isEmpty { cfg.anthropicApiKey = k }
        if let f = env["GHOSTIE_NOTES_FOLDER"], !f.isEmpty { cfg.notesFolder = f }
        if let m = env["GHOSTIE_WHISPER_MODEL"], !m.isEmpty { cfg.whisperModel = m }
        if let s = env["GHOSTIE_SUMMARY_MODEL"], !s.isEmpty { cfg.summaryModel = s }
        // Key entered via the menu bar this session wins (no restart needed).
        if let k = runtimeConfigOverrideKey, !k.isEmpty { cfg.anthropicApiKey = k }
        if cfg.whisperBinary.isEmpty { cfg.whisperBinary = Config.findWhisperBinary() }
        return cfg
    }

    static func findWhisperBinary() -> String {
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

    func writeExampleIfMissing() {
        let dir = (Config.configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: Config.configPath) else { return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(self) {
            try? data.write(to: URL(fileURLWithPath: Config.configPath))
        }
    }
}
