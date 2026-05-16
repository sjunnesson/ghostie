import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation

// MARK: - Headless daemon (launchd / no GUI session)

final class HeadlessRunner {
    private let engine: Engine
    private var signalSources: [DispatchSourceSignal] = []

    init(config: Config) { engine = Engine(config: config) }

    func run() {
        let t = Transcriber(config: engine.config)
        Log.info("Transcription: \(t.isAvailable ? "local whisper.cpp ✓" : "NOT set up — run scripts/setup.sh")")
        Log.info("Summaries: \(Summarizer(config: engine.config).isConfigured ? "claude -p ✓" : "disabled (Claude Code CLI not found — run `claude` once to log in)")")
        engine.startListening()

        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for sig in [SIGINT, SIGTERM] {
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler {
                Log.info("Shutting down…")
                self.engine.shutdown { exit(0) }
            }
            src.resume()
            signalSources.append(src)
        }
        RunLoop.main.run()
    }
}

// MARK: - One-shot CLI helpers

func runBlocking(_ body: @escaping () async -> Void) {
    let sem = DispatchSemaphore(value: 0)
    Task { await body(); sem.signal() }
    sem.wait()
}

func cmdTestRecord(_ config: Config, seconds: Double) {
    Log.info("Test recording for \(Int(seconds))s — speak into your mic and play some audio…")
    let rec = AudioRecorder(config: config)
    let started = Date()
    runBlocking {
        do {
            try await rec.start()
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let result = await rec.stop() else { Log.error("No result."); return }
            Log.ok("Captured \(String(format: "%.1f", result.duration))s. Running pipeline…")
            Pipeline(config: config).process(result, startedAt: started)
        } catch {
            Log.error("Test failed: \(error.localizedDescription)")
            Log.error("Grant Screen Recording + Microphone in System Settings ▸ Privacy & Security.")
        }
    }
}

func cmdProcess(_ config: Config, dir: String) {
    let url = URL(fileURLWithPath: dir)
    let mic = url.appendingPathComponent("me.wav")
    let sys = url.appendingPathComponent("participants.wav")
    guard FileManager.default.fileExists(atPath: mic.path) ||
          FileManager.default.fileExists(atPath: sys.path) else {
        Log.error("No me.wav / participants.wav found in \(dir)"); return
    }
    let result = AudioRecorder.Result(sessionDir: url, micWav: mic,
                                      systemWav: sys, duration: 0)
    Pipeline(config: config).process(result, startedAt: Date())
}

func cmdDoctor(_ config: Config) {
    print("Ghostie doctor\n==================")
    let t = Transcriber(config: config)
    let s = Summarizer(config: config)
    func row(_ ok: Bool, _ label: String, _ detail: String = "") {
        print("  \(ok ? "✓" : "✗") \(label)\(detail.isEmpty ? "" : "  — \(detail)")")
    }
    row(!config.whisperBinary.isEmpty, "whisper.cpp binary", config.whisperBinary.isEmpty ? "brew install whisper-cpp" : config.whisperBinary)
    row(FileManager.default.fileExists(atPath: config.whisperModel), "whisper model", config.whisperModel)
    row(t.isAvailable, "transcription ready")
    row(config.cleanTranscript, "hallucination guard",
        config.cleanTranscript ? "on (run `ghostie selftest` to verify)" : "disabled in config")
    let vadOn = !config.vadModel.isEmpty && FileManager.default.fileExists(atPath: config.vadModel)
    row(vadOn, "Silero VAD model", vadOn ? config.vadModel : "optional — ./scripts/setup.sh --vad")
    row(s.isConfigured, "Claude Code CLI (`claude -p`)",
        s.isConfigured ? s.claudeBinary : "not found — install Claude Code and run `claude` once to log in")
    let teams = NSWorkspace.shared.runningApplications.contains {
        ($0.bundleIdentifier?.lowercased().hasPrefix("com.microsoft.teams") ?? false)
    }
    row(teams, "Microsoft Teams running", teams ? "" : "(only needed during a call)")
    row(CallDetector.defaultInputDevice() != nil, "default input device detected")
    let pending = Backlog.pendingCount
    row(pending == 0, "backlog",
        pending == 0 ? "empty" : "\(pending) pending — auto-retried; `ghostie process-backlog` to force")
    print("\n  Notes folder: \(config.notesFolder)")
    print("  Config file:  \(Config.configPath)")
    print("\n  Screen Recording + Microphone permissions are requested on first")
    print("  capture. Grant them to the app in System Settings ▸ Privacy & Security.")
}

func serviceLabel() -> String { "com.davidsjunnesson.ghostie" }
func servicePlistPath() -> String {
    "\(NSHomeDirectory())/Library/LaunchAgents/\(serviceLabel()).plist"
}

func cmdInstallService(_ config: Config) {
    let binary = CommandLine.arguments[0]
    let abs = (binary as NSString).isAbsolutePath
        ? binary : FileManager.default.currentDirectoryPath + "/" + binary
    let plist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
      <key>Label</key><string>\(serviceLabel())</string>
      <key>ProgramArguments</key>
      <array><string>\(abs)</string><string>run</string></array>
      <key>RunAtLoad</key><true/>
      <key>KeepAlive</key><true/>
      <key>StandardOutPath</key><string>\(NSHomeDirectory())/.ghostie/service.out.log</string>
      <key>StandardErrorPath</key><string>\(NSHomeDirectory())/.ghostie/service.err.log</string>
      <key>EnvironmentVariables</key>
      <dict><key>PATH</key><string>\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string></dict>
    </dict>
    </plist>
    """
    let dir = "\(NSHomeDirectory())/Library/LaunchAgents"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? plist.write(toFile: servicePlistPath(), atomically: true, encoding: .utf8)
    _ = shell("/bin/launchctl", ["unload", servicePlistPath()])
    _ = shell("/bin/launchctl", ["load", servicePlistPath()])
    Log.ok("Headless service installed: \(serviceLabel())")
    print("Tip: for quick access, use the menu bar app instead (open Ghostie.app).")
}

func cmdUninstallService() {
    _ = shell("/bin/launchctl", ["unload", servicePlistPath()])
    try? FileManager.default.removeItem(atPath: servicePlistPath())
    Log.ok("Service uninstalled.")
}

@discardableResult
func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe; p.standardError = pipe
    try? p.run(); p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func launchMenuBar(_ config: Config) {
    let app = NSApplication.shared
    let delegate = MenuBarApp(config: config)
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

/// Opens just the Settings window (used by `ghostie settings`, and a handy
/// way to edit config without the menu bar running).
func launchSettingsOnly() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let win = SettingsWindow { newCfg in
        Log.ok("Settings saved → \(Config.configPath)")
        _ = newCfg
    }
    win.onClose = { NSApp.terminate(nil) }
    win.show()
    app.run()
}

/// Built-in regression check for the hallucination guard, over the patterns
/// it targets (whisper emits these as separate short segments on bad audio).
func runTranscriptCleanerSelfTest() -> Bool {
    func seg(_ texts: [String]) -> [(startMs: Int, text: String)] {
        texts.enumerated().map { (startMs: $0.offset * 1000, text: $0.element) }
    }
    var passed = 0, failed = 0
    func check(_ name: String, _ input: [String], _ predicate: ([String]) -> Bool) {
        let (out, stats) = TranscriptCleaner.clean(seg(input))
        let texts = out.map { $0.text }
        if predicate(texts) {
            passed += 1; print("  ✓ \(name)  (\(stats.summary))")
        } else {
            failed += 1
            print("  ✗ \(name)\n      in:  \(input)\n      out: \(texts)")
        }
    }

    // Silence loop → collapses to one + an annotation.
    check("silence loop collapses", Array(repeating: "Thank you.", count: 12)
          + ["What is the Q3 budget?"]) { out in
        out.contains { $0.contains("repeated audio removed") }
        && out.contains { $0.contains("Q3 budget") }
        && out.filter { $0 == "Thank you." }.count <= 1
    }
    // YouTube / Amara training-data leaks dropped; real content kept.
    check("known hallucinations dropped",
          ["Thanks for watching!", "Please subscribe to our channel",
           "Subtitles by the Amara.org community", "www.amara.org",
           "Let's approve the migration plan."]) { out in
        out == ["Let's approve the migration plan."]
    }
    // Noise-marker run collapses; trailing noise trimmed.
    check("noise markers + trailing trim",
          ["Decision: ship Friday.", "[BLANK_AUDIO]", "[BLANK_AUDIO]",
           "[BLANK_AUDIO]", "[ Silence ]", "[music]"]) { out in
        out == ["Decision: ship Friday."]
    }
    // A dominant hallucinated *content* phrase interleaved with junk
    // collapses to one occurrence; pure filler backchannel is intentionally
    // preserved, so the dominant phrase here is real-looking content.
    check("interleaved drift collapses",
          ["The meeting is being recorded.", "uh",
           "The meeting is being recorded.", "um",
           "The meeting is being recorded.", "hmm",
           "The meeting is being recorded.", "okay",
           "The meeting is being recorded.", "right",
           "The meeting is being recorded.", "Decision: launch next week."]) { out in
        out.filter { $0 == "The meeting is being recorded." }.count == 1
        && out.contains { $0.contains("Decision: launch next week.") }
        && out.count < 12
    }
    // Clean speech is untouched (no false positives).
    check("clean speech untouched",
          ["Hi everyone.", "We shipped the feature.", "Next steps are clear.",
           "Thanks, talk soon."]) { out in
        out == ["Hi everyone.", "We shipped the feature.",
                "Next steps are clear.", "Thanks, talk soon."]
    }

    print("\ntranscript-cleaner self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}

func printHelp() {
    print("""
    Ghostie — local Teams call transcriber & summarizer (no bot joins).

    USAGE: ghostie <command>

      menubar             Run as a macOS menu bar app (default when launched
                          as Ghostie.app).
      run                 Headless watch loop (launchd / servers).
      test-record [secs]  Record N seconds (default 15) → full pipeline.
      process <dir>       Re-run transcription+summary on a recording dir.
      doctor              Check dependencies & permissions.
      process-backlog     Process recordings queued while deps were unavailable.
      selftest            Verify the transcript hallucination guard.
      install-service     Headless background service via launchd.
      uninstall-service   Remove the headless service.
      help                Show this help.

    Build the menu bar app:  ./scripts/build-app.sh
    Config: \(Config.configPath)
    """)
}

// MARK: - Entry

let config = Config.load()
config.writeExampleIfMissing()

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first
// Running inside a packaged .app bundle → default to the menu bar UI.
let isAppBundle = Bundle.main.bundleIdentifier != nil
    || Bundle.main.bundlePath.hasSuffix(".app")

switch command {
case "menubar":
    launchMenuBar(config)
case "run":
    HeadlessRunner(config: config).run()
case "test-record":
    cmdTestRecord(config, seconds: Double(args.count > 1 ? args[1] : "") ?? 15)
case "process":
    guard args.count > 1 else { Log.error("Usage: ghostie process <dir>"); exit(1) }
    cmdProcess(config, dir: args[1])
case "doctor":
    cmdDoctor(config)
case "process-backlog":
    let n = Pipeline.drain(config: config)
    print("Backlog: completed \(n); \(Backlog.pendingCount) still pending.")
case "icon":
    // Hidden: render the app icon PNG (used by scripts/build-app.sh).
    let out = args.count > 1 ? args[1] : "icon.png"
    exit(GhostIcon.writeAppIconPNG(to: out) ? 0 : 1)
case "selftest":
    exit(runTranscriptCleanerSelfTest() ? 0 : 1)
case "settings":
    launchSettingsOnly()
case "install-service":
    cmdInstallService(config)
case "uninstall-service":
    cmdUninstallService()
case "help", "-h", "--help":
    printHelp()
case nil:
    // No arguments: menu bar app when bundled, otherwise headless.
    if isAppBundle { launchMenuBar(config) } else { HeadlessRunner(config: config).run() }
default:
    Log.error("Unknown command: \(command ?? "")")
    printHelp()
    exit(1)
}
