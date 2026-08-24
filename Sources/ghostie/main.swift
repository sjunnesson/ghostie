import Foundation
import AppKit
import ScreenCaptureKit
import AVFoundation

// MARK: - Headless daemon (launchd / no GUI session)

final class HeadlessRunner {
    private let engine: Engine
    private var signalSources: [DispatchSourceSignal] = []
    private var updateTimer: DispatchSourceTimer?
    private let updater = Updater()

    init(config: Config) { engine = Engine(config: config) }

    func run() {
        CrashBreadcrumb.install()
        let t = Transcriber(config: engine.config)
        Log.info("Transcription: \(t.isAvailable ? "local whisper.cpp ✓" : "NOT set up — run scripts/setup.sh")")
        Log.info("Summaries: \(Summarizer(config: engine.config).isConfigured ? "claude -p ✓" : "disabled (Claude Code CLI not found — run `claude` once to log in)")")
        engine.startListening()

        // A launchd daemon never self-swaps (it could be recording); it only
        // logs that an update is waiting — install via the app or CLI.
        if Updater.runningBuildSupportsOTA() {
            let ut = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "ghostie.updatecheck"))
            ut.schedule(deadline: .now() + 86_400, repeating: 86_400)
            ut.setEventHandler { [weak self] in
                guard let self, Config.loadRaw().autoCheckUpdates else { return }
                self.updater.check(config: Config.load()) { result in
                    if case .success(.available(let r, let cur)) = result {
                        Log.info("Update available: \(cur) → \(r.tag). Open Ghostie.app or run `ghostie update --install`.")
                    }
                }
            }
            ut.resume()
            updateTimer = ut
        }

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
            guard let result = await rec.stop(discardIfBelowMinCallSeconds: false) else { Log.error("No result."); return }
            Log.ok("Captured \(String(format: "%.1f", result.duration))s. Running pipeline…")
            Pipeline(config: config).process(result, startedAt: started, source: "Test")
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

/// Headless equivalent of the Settings "Download models" button. Uses the
/// `Models` manifest so GUI and CLI/servers fetch identical artifacts.
///
/// Selection rules (priority order):
///   - `--all`           → every model Ghostie can use, regardless of config.
///   - `--codeswitch`    → the codeswitch set (KB-Whisper + large-v3 + VAD).
///   - `--vad`           → just the Silero VAD model.
///   - explicit variant  → codeswitch set with that KB variant.
///   - no arg            → whatever `Models.required(for:)` reports for the
///                         current config (codeswitch or single-mode).
func cmdFetchModels(_ config: Config, args: [String]) {
    let wantsAll = args.contains("--all")
    let wantsCodeswitch = args.contains("--codeswitch")
    let wantsVAD = args.contains("--vad")
    let wantsDiarization = args.contains("--diarization")
    let explicitVariant = args.first { !$0.hasPrefix("--") }
    let variant = explicitVariant ?? config.codeSwitch.kbWhisperVariant

    var models: [Model] = []
    if wantsAll {
        models = [Models.baseEnglish, Models.largeV3, Models.sileroVAD,
                  Models.speakerEmbedding]
        if let kb = Models.kbWhisperLarge(variant: variant) { models.insert(kb, at: 1) }
    } else if wantsDiarization {
        models = [Models.speakerEmbedding]
    } else if wantsCodeswitch || explicitVariant != nil {
        guard let kb = Models.kbWhisperLarge(variant: variant) else {
            Log.error(ModelDownloader.DLError.subtitleUnavailable.localizedDescription)
            exit(1)
        }
        models = [kb, Models.largeV3, Models.sileroVAD]
    } else if wantsVAD {
        models = [Models.sileroVAD]
    } else {
        models = Models.required(for: config)
    }

    Log.info("Fetching \(models.count) model(s) → \(Config.modelsDir)")
    let dl = ModelDownloader()
    var failure: Error?
    var done = false
    dl.start(models: models,
             status: { Log.info($0) },
             finish: { err in failure = err; done = true })
    while !done {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }
    if let failure {
        Log.error("Download failed: \(failure.localizedDescription)")
        exit(1)
    }
    Log.ok("Done. Run `ghostie doctor models` to re-verify on demand.")
}

/// `ghostie doctor models` — hash every required model against the SHA256
/// captured at download time (sidecar `<model>.meta`). On-demand, not on
/// launch: hashing a 1 GB file is ~3 sec on Apple Silicon.
///
/// Files that exist but pre-date the sidecar are *adopted* in-place: HEAD
/// the URL to learn the upstream SHA256, hash the local file, and if they
/// match write the sidecar so future runs are offline-fast. This means
/// upgrading from older Ghostie builds doesn't force a 2 GB re-download.
func cmdDoctorModels(_ config: Config) {
    print("Ghostie doctor: models\n==================")
    let models = Models.required(for: config)
    if models.isEmpty {
        print("  (no models required for current config)"); return
    }
    var healths = ModelDownloader.health(for: models)

    // Adopt legacy files (no sidecar) by HEAD-ing the URL and hashing on disk.
    let needsAdoption = healths.contains { h in
        if case .noSidecar = h.state { return true } else { return false }
    }
    if needsAdoption {
        print("  Adopting \(healths.filter { if case .noSidecar = $0.state { return true } else { return false } }.count) legacy file(s) (HEAD + SHA256)…")
        healths = healths.map { h in
            if case .noSidecar = h.state {
                return ModelDownloader.Health(model: h.model,
                                              state: ModelDownloader.adopt(h.model))
            }
            return h
        }
        print("")
    }

    var allOK = true
    for h in healths {
        let mark = h.state.isOK ? "✓" : "✗"
        if !h.state.isOK { allOK = false }
        print("  \(mark) \(h.model.filename)  — \(h.state.summary)")
        if !h.state.isOK {
            print("      URL: \(h.model.url.absoluteString)")
        }
    }
    print("")
    if allOK {
        print("All required models verified.")
    } else {
        print("Some models need repair. Run:")
        print("  ghostie fetch-models --all")
        print("to re-download anything missing or mismatched (intact files are skipped).")
        exit(1)
    }
}

/// `ghostie update [--install]` — check GitHub Releases; with `--install`
/// download, verify (notarization + checksum) and swap the running .app.
func cmdUpdate(_ config: Config, install: Bool) {
    if !Updater.runningBuildSupportsOTA() {
        print("This build can't self-update (not a notarized Developer ID build).")
        print("Download the latest from \(Updater.releasesPage.absoluteString)")
        exit(0)
    }
    let up = Updater()
    var result: Result<UpdateAvailability, Error>?
    up.check(config: config) { result = $0 }
    while result == nil {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
    }
    let availability: UpdateAvailability
    switch result! {
    case .success(let a): availability = a
    case .failure(let e):
        Log.error("Update check failed: \(e.localizedDescription)")
        exit(1)
    }
    switch availability {
    case .skippedUnsupportedBuild:
        print("This build can't self-update. Download from \(Updater.releasesPage.absoluteString)")
        exit(0)
    case .upToDate(let cur):
        Log.ok("Ghostie \(cur) is the latest version.")
        exit(0)
    case .available(let rel, let cur):
        print("Update available: \(cur) → \(rel.tag)")
        if !rel.notes.isEmpty { print("\n\(rel.notes)\n") }
        if !install {
            print("Run `ghostie update --install` to download, verify and install it.")
            exit(0)
        }
        Log.info("Downloading and verifying \(rel.tag)…")
        var failed: Error?
        var committed = false
        var finishedFlag = false
        up.downloadAndInstall(rel, engine: nil,
            status: { Log.info($0) },
            finish: { err in failed = err; finishedFlag = true },
            commit: { committed = true })
        while !committed && !finishedFlag {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.2))
        }
        if let failed {
            Log.error("Update failed: \(failed.localizedDescription)")
            exit(1)
        }
        // committed: the detached helper waits for this process to exit, then
        // swaps the bundle and relaunches.
        Log.ok("Installing \(rel.tag) — Ghostie will relaunch.")
        exit(0)
    }
}

/// `ghostie diagnose-detect [--duration N] [--json]` — live readout of the
/// detector for N seconds. Refresh is 500 ms. JSON mode emits one
/// line-delimited JSON object per tick; selftest asserts each line parses.
func cmdDiagnoseDetect(_ config: Config, durationSeconds: Double, jsonMode: Bool) {
    DiagnoseDetect.run(config: config, duration: durationSeconds, jsonMode: jsonMode) { line in
        print(line)
        fflush(stdout)
    }
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
    row(config.micEchoCancellation, "mic echo cancellation",
        config.micEchoCancellation
            ? "on (voice-processed mic; raw-tap fallback is automatic)"
            : "disabled in config — expect speaker echo on the 'Me' track without headphones")
    let vadOn = !config.vadModel.isEmpty && FileManager.default.fileExists(atPath: config.vadModel)
    row(vadOn, "Silero VAD model", vadOn ? config.vadModel : "optional — ./scripts/setup.sh --vad")

    // Speaker labelling. "Me" vs "Participants" always works — it comes from
    // the two capture tracks, not a model. These two rows are about splitting
    // the far end into individual people and giving them names.
    let spkPath = config.speakerModel.isEmpty
        ? SpeakerEmbedder.defaultModelPath : config.speakerModel
    let spkModel = FileManager.default.fileExists(atPath: spkPath)
    let ortOK = ORTRuntime.shared != nil
    let diarizeOK = config.diarization && spkModel && ortOK
    row(diarizeOK, "speaker diarization",
        !config.diarization ? "disabled in config — the far end stays one 'Participants' label"
            : !spkModel ? "no embedding model — `ghostie fetch-models --diarization`"
            : !ortOK ? "ONNX Runtime not found — `brew install onnxruntime`, or use a bundled build"
            : "on — the Participants track is split per speaker")
    row(config.nameSpeakers && s.isConfigured, "speaker naming",
        !config.nameSpeakers ? "disabled in config — labels stay generic"
            : !s.isConfigured ? "needs a working summarization provider (see below)"
            : config.userName.isEmpty ? "on — names are read from the conversation"
            : "on — you are \(config.userName); others are read from the conversation")
    switch config.summaryProvider {
    case "ollama":
        let detail = s.isConfigured
            ? "\(config.ollamaUrl) — model \(config.ollamaModel)"
            : "not ready — set the server URL and model in Settings (or pull a model with `ollama pull`)"
        row(s.isConfigured, "Ollama (local, `/api/chat`)", detail)
    default:
        let claudePath = config.claudeBinary.isEmpty ? Config.findClaudeBinary() : config.claudeBinary
        row(s.isConfigured, "Claude Code CLI (`claude -p`)",
            s.isConfigured ? claudePath : "not found — install Claude Code and run `claude` once to log in")
    }
    // Languages: rendered straight off `LanguageSetup`, the same struct the
    // Settings pane draws — doctor and the UI can't disagree about what will
    // happen because they are reading one computation, not two.
    let cs = config.codeSwitch
    let installed = Models.installed(preferredKBVariant: cs.kbWhisperVariant)
    let setup = LanguageSetup.resolve(config: config)
    row(true, "languages installed on disk",
        installed.languages.isEmpty
            ? "none — single-language path only"
            : installed.languages.joined(separator: ", "))
    row(true, "languages configured",
        setup.isConfigured
            ? setup.rows.map(\.code).joined(separator: ", ")
            : "none — the disk is the whitelist")
    // KB-Whisper's language head is Swedish-biased; with no English-capable
    // model on disk, English audio gets decoded (and language-detected) by it.
    if installed.modelPath(for: "en") == nil, installed.languages.contains("sv") {
        row(false, "English-capable model",
            "none installed — English audio will be decoded by KB-Whisper (Swedish-biased); fetch large-v3 or base.en")
    }
    switch setup.mode {
    case .unconfigured:
        row(false, "transcription mode", "no usable model — add a language in Settings")
    case .single(let lang):
        row(true, "transcription mode",
            "single-language (\(lang)) — quality preference \(config.transcriptionQuality)")
    case .codeSwitch(let langs):
        row(true, "transcription mode",
            "code-switching — \(langs.joined(separator: "+")), dominant \(cs.effectiveDominant(installed: installed)), KB variant \(cs.kbWhisperVariant)")
        let lid = LanguageSegmenter.defaultIdentifier(config: config, installed: installed)
        row(true, "  language identifier (LID)", lid.description)
        row(setup.detectionModelLabel != nil, "  detection driver",
            setup.detectionModelLabel ?? "none — no balanced multilingual model installed")
    }
    for r in setup.rows {
        let detail = [r.modelLabel, r.drivesDetection ? "drives detection" : nil,
                      r.isPrimary ? "primary" : nil]
            .compactMap { $0 }.joined(separator: " · ")
        switch r.state {
        case .onDisk:  row(true,  "  \(r.code)", detail)
        case .missing: row(false, "  \(r.code)", "\(detail) — not downloaded")
        case .none:    row(false, "  \(r.code)", "no model known for this language")
        }
    }
    let vadOK = !config.vadModel.isEmpty
        && FileManager.default.fileExists(atPath: config.vadModel)
    if case .codeSwitch = setup.mode {
        row(vadOK, "  Silero VAD (required by code-switching)",
            vadOK ? config.vadModel : "missing — scripts/setup.sh --codeswitch fetches it")
    }

    let matchers = config.triggerBundleIds.map { $0.lowercased() }
    let meetingApp = NSWorkspace.shared.runningApplications.contains {
        guard let b = $0.bundleIdentifier else { return false }
        return DetectionCoordinator.matchesTriggerBundle(b, matchers: matchers)
    }
    row(meetingApp, "meeting app running (Teams/Zoom)",
        meetingApp ? "" : "(only needed during a call)")
    row(CallDetector.defaultInputDevice() != nil, "default input device detected")
    if let free = freeDiskBytes(at: config.workDir) {
        row(free >= lowDiskThresholdBytes, "free disk space",
            free >= lowDiskThresholdBytes
                ? mbString(free)
                : "\(mbString(free)) — below \(mbString(lowDiskThresholdBytes)); recordings and backlog writes may fail")
    }
    let pending = Backlog.pendingCount
    row(pending == 0, "backlog",
        pending == 0 ? "empty" : "\(pending) pending — auto-retried; `ghostie process-backlog` to force")

    // MARK: Permissions
    //
    // Each row shows the TCC verdict for the CURRENTLY RUNNING binary. If
    // that binary is the .app bundle, the verdict reflects /Applications/
    // Ghostie.app. If it's `.build/debug/ghostie`, you're seeing the verdict
    // for an ad-hoc-signed CLI that TCC keys to a different identity than
    // the app — granting permissions to one does not transfer to the other.
    print("\nPermissions (this binary)")
    let binaryPath = CommandLine.arguments[0]
    let isAppBundle = binaryPath.contains(".app/Contents/MacOS/")
    print("  Binary: \(binaryPath)")
    if !isAppBundle {
        print("  ⚠︎  Running an ad-hoc-signed CLI. TCC will not share grants")
        print("     with /Applications/Ghostie.app. To test the real")
        print("     permission flow, launch Ghostie.app and run doctor")
        print("     via the menu bar's 'Diagnostics' item.")
    }
    let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    row(micStatus == .authorized, "Microphone",
        micStatus == .authorized ? "granted" :
        micStatus == .denied ? "DENIED — System Settings ▸ Privacy & Security ▸ Microphone" :
        micStatus == .restricted ? "restricted (MDM profile)" :
        "not yet requested (fires on first call detection)")
    let axOK = AXIsProcessTrusted()
    row(axOK, "Accessibility",
        axOK ? "granted (AX corroborator active)" :
        "not granted — detection still works on audio I/O alone. Grant in System Settings ▸ Privacy & Security ▸ Accessibility for a third signal.")
    // Screen Recording has no public preflight API. CGPreflightScreenCaptureAccess
    // is available since macOS 10.15 and returns true if access is allowed
    // without prompting.
    let srOK = CGPreflightScreenCaptureAccess()
    row(srOK, "Screen Recording",
        srOK ? "granted (required for capturing other participants' voices)" :
        "not granted — System Settings ▸ Privacy & Security ▸ Screen Recording. The next captured call will prompt.")

    print("\n  Notes folder: \(config.notesFolder)")
    print("  Config file:  \(Config.configPath)")
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
    runProcess(path, args).output
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

func printHelp() {
    print("""
    Ghostie — local meeting-call transcriber & summarizer (no bot joins).
    Detects Microsoft Teams and Zoom desktop calls out of the box; Teams and
    Google Meet in the browser are opt-in (Settings ▸ Listening).

    USAGE: ghostie <command>

      menubar             Run as a macOS menu bar app (default when launched
                          as Ghostie.app).
      run                 Headless watch loop (launchd / servers).
      test-record [secs]  Record N seconds (default 30) → full pipeline.
      process <dir>       Re-run transcription+summary on a recording dir.
      doctor              Check dependencies & permissions.
      doctor models       SHA256-verify every required model against the
                          sidecar from its last successful download.
      diagnose-detect [--duration N] [--json]
                          Live readout of the call detector. 30s default,
                          500ms refresh. --json emits line-delimited JSON.
      fetch-models [variant] [--all|--codeswitch|--vad|--diarization]
                          Download the model set Ghostie needs. With no flag,
                          fetches exactly what current config requires (single
                          mode → base.en + VAD; codeswitch on → KB + large-v3
                          + VAD). Each download is SHA256-verified against
                          Hugging Face's `x-linked-etag`; intact files skip.
      process-backlog     Process recordings queued while deps were unavailable.
      update [--install]  Check for a newer release; --install downloads,
                          verifies (notarization + SHA-256) and swaps the app.
      selftest            Verify the hallucination guard + code-switching
                          smoother + updater version/manifest logic.
      install-service     Headless background service via launchd.
      uninstall-service   Remove the headless service.
      help                Show this help.

    Build the menu bar app:  ./scripts/build-app.sh
    Config: \(Config.configPath)
    """)
}

// MARK: - diarize-probe (hidden)

/// Field debugging for speaker diarization: chops a WAV into fixed-length
/// segments, clusters them, and prints who the diarizer thinks is speaking
/// when. Fixed segments (rather than Whisper's) keep the probe independent of
/// transcription, so it answers "can the embeddings tell these voices apart?"
/// on its own.
func cmdDiarizeProbe(_ config: Config, wavPath: String, segmentMs: Int) {
    guard let embedder = SpeakerEmbedder.load(config: config) else {
        print("diarize-probe: speaker embedding unavailable"); exit(1)
    }
    defer { embedder.shutdown() }
    let url = URL(fileURLWithPath: wavPath)
    guard let samples = try? AudioStitcher.readPCM(url) else {
        print("diarize-probe: could not read \(wavPath)"); exit(1)
    }
    let floats = SpeakerDiarizer.floatSamples(samples)
    let totalMs = floats.count * 1000 / Fbank.sampleRate
    var segments: [Transcriber.Segment] = []
    var t = 0
    while t + segmentMs <= totalMs {
        segments.append(Transcriber.Segment(startMs: t, text: "", endMs: t + segmentMs))
        t += segmentMs
    }
    print("\(segments.count) segments of \(segmentMs) ms over \(String(format: "%.1f", Double(totalMs) / 60_000)) min")
    let t0 = Date()
    var diarizer = SpeakerDiarizer()
    diarizer.fillUnlabelled = ProcessInfo.processInfo.environment["GHOSTIE_DIARIZE_NOFILL"] == nil
    guard let a = diarizer.diarize(segments: segments, samples: floats,
                                   embedder: embedder) else {
        print("verdict: a single speaker (or too little audio to split)")
        return
    }
    print(a.summary)
    print(String(format: "embedded + clustered in %.1f s", Date().timeIntervalSince(t0)))
    var line = ""
    for (i, s) in a.speakers.enumerated() {
        line += s.map { String($0) } ?? "."
        if (i + 1) % 60 == 0 { print("  \(line)"); line = "" }
    }
    if !line.isEmpty { print("  \(line)") }
}

// MARK: - embed-dump (hidden, diagnostics)

/// Prints one L2-normalized speaker embedding per fixed-length segment as
/// TSV, for offline analysis of separability.
func cmdEmbedDump(_ config: Config, wavPath: String, segmentMs: Int) {
    guard let embedder = SpeakerEmbedder.load(config: config) else { exit(1) }
    defer { embedder.shutdown() }
    guard let pcm = try? AudioStitcher.readPCM(URL(fileURLWithPath: wavPath)) else { exit(1) }
    let f = SpeakerDiarizer.floatSamples(pcm)
    let step = Fbank.sampleRate * segmentMs / 1000
    var i = 0, n = 0
    while i + step <= f.count {
        if let e = embedder.embed(Array(f[i..<(i + step)])) {
            print("\(n)\t" + e.map { String(format: "%.5f", $0) }.joined(separator: ","))
        }
        i += step; n += 1
    }
}

// MARK: - wav-probe (hidden)

/// Field debugging for the "half-recorded call" class of bug: prints the
/// signal level of a session's tracks and the verdict the pipeline would
/// reach. `ghostie wav-probe ~/.ghostie/recordings/<session>` answers "was my
/// microphone actually recording?" without re-running an hour of transcription.
func cmdWavProbe(_ path: String) {
    let url = URL(fileURLWithPath: path)
    var isDir: ObjCBool = false
    FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
    let wavs: [(String, URL)] = isDir.boolValue
        ? [("me", url.appendingPathComponent("me.wav")),
           ("participants", url.appendingPathComponent("participants.wav"))]
        : [(url.lastPathComponent, url)]

    for (label, wav) in wavs {
        guard FileManager.default.fileExists(atPath: wav.path) else {
            print("\(label): missing (\(wav.path))"); continue
        }
        guard let st = WavLevel.probe(wav) else {
            print("\(label): unreadable"); continue
        }
        let dbfs = st.peak == 0
            ? "-inf" : String(format: "%.1f", 20 * log10(Double(st.peak) / 32768))
        let name = label.padding(toLength: max(13, label.count), withPad: " ",
                                 startingAt: 0)
        print(name
              + String(format: " %6.1f min  peak %7s dBFS  active %5.1f%%",
                       st.seconds / 60, (dbfs as NSString).utf8String!,
                       st.activeFraction * 100)
              + (st.isDigitalSilence ? "   ← DIGITAL SILENCE" : ""))
    }
    if isDir.boolValue {
        let verdict = Pipeline.trackHealthWarning(
            mic: url.appendingPathComponent("me.wav"),
            sys: url.appendingPathComponent("participants.wav"))
        print("verdict: " + (verdict ?? "both tracks carry audio."))
    }
}

// MARK: - lid-probe (hidden)

/// Hidden field-debugging subcommand: builds the default language identifier
/// (resident whisper-server when available, else spawn-per-segment
/// whisper-cli), runs it on one 16 kHz mono WAV, prints the posterior, and
/// shuts the server down. Not part of any pipeline and not listed in help.
func cmdLidProbe(_ config: Config, wavPath: String) {
    let installed = Models.installed(preferredKBVariant: config.codeSwitch.kbWhisperVariant)
    var restrict = config.codeSwitch.effectiveLanguages(installed: installed)
    if restrict.count < 2 { restrict = ["en", "sv"] }
    let lid = LanguageSegmenter.defaultIdentifier(config: config, installed: installed)
    defer { lid.shutdown() }
    print("identifier: \(lid.description)")
    print("whitelist:  \(restrict.joined(separator: ", "))")
    do {
        let pcm = try AudioStitcher.readPCM(URL(fileURLWithPath: wavPath))
        let t0 = Date()
        let posterior = try lid.identify(pcm: pcm, sampleRateHz: 16_000, restrict: restrict)
        let elapsed = Date().timeIntervalSince(t0)
        for (lang, lp) in posterior.sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %@  p=%.4f  (logp %+.4f)", lang, Foundation.exp(lp), lp))
        }
        print(String(format: "identified in %.2f s", elapsed))
    } catch {
        print("lid-probe failed: \(error.localizedDescription)")
        lid.shutdown()   // exit() skips the defer — tear down explicitly
        exit(1)
    }
}

// MARK: - Entry

let config = Config.load()
config.writeExampleIfMissing()
ModelCatalog.seedIfMissing()

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
    cmdTestRecord(config, seconds: Double(args.count > 1 ? args[1] : "") ?? 30)
case "process":
    guard args.count > 1 else { Log.error("Usage: ghostie process <dir>"); exit(1) }
    cmdProcess(config, dir: args[1])
case "fetch-models":
    cmdFetchModels(config, args: Array(args.dropFirst()))
case "doctor":
    if args.count > 1 && args[1] == "models" {
        cmdDoctorModels(config)
    } else {
        cmdDoctor(config)
    }
case "diagnose-detect":
    var dur = 30.0
    if let i = args.firstIndex(of: "--duration"), i + 1 < args.count,
       let v = Double(args[i + 1]) { dur = v }
    let json = args.contains("--json")
    cmdDiagnoseDetect(config, durationSeconds: dur, jsonMode: json)
case "process-backlog":
    let n = Pipeline.drain(config: config)
    print("Backlog: completed \(n); \(Backlog.pendingCount) still pending.")
case "icon":
    // Hidden: render the app icon PNG (used by scripts/build-app.sh).
    let out = args.count > 1 ? args[1] : "icon.png"
    exit(GhostIcon.writeAppIconPNG(to: out) ? 0 : 1)
case "diarize-probe":
    // Hidden: cluster a WAV's speakers on fixed segments and print a timeline.
    guard args.count > 1 else {
        Log.error("Usage: ghostie diarize-probe <wav> [segment-ms]"); exit(1)
    }
    cmdDiarizeProbe(config, wavPath: args[1],
                    segmentMs: Int(args.count > 2 ? args[2] : "") ?? 3000)
case "embed-dump":
    guard args.count > 1 else { Log.error("Usage: ghostie embed-dump <wav> [ms]"); exit(1) }
    cmdEmbedDump(config, wavPath: args[1], segmentMs: Int(args.count > 2 ? args[2] : "") ?? 3000)
case "wav-probe":
    // Hidden: report per-track signal level for a session dir or a WAV.
    guard args.count > 1 else {
        Log.error("Usage: ghostie wav-probe <session-dir|wav>"); exit(1)
    }
    cmdWavProbe(args[1])
case "lid-probe":
    // Hidden: run the active language identifier on a WAV (field debugging).
    guard args.count > 1 else { Log.error("Usage: ghostie lid-probe <wav>"); exit(1) }
    cmdLidProbe(config, wavPath: args[1])
case "update":
    cmdUpdate(config, install: args.contains("--install"))
case "selftest":
    let cleanerOK = runTranscriptCleanerSelfTest()
    print("")
    let echoOK = runEchoSuppressorSelfTest()
    print("")
    let codeSwitchOK = runCodeSwitchSelfTest()
    print("")
    let updaterOK = runUpdaterSelfTest()
    print("")
    let detectorOK = runDetectorStateMachineSelfTest()
    print("")
    let wavOK = runWavLevelSelfTest()
    print("")
    let speakerOK = runSpeakerSelfTest()
    exit(cleanerOK && echoOK && codeSwitchOK && updaterOK && detectorOK && wavOK
         && speakerOK ? 0 : 1)
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
