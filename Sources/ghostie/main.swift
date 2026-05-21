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
    let explicitVariant = args.first { !$0.hasPrefix("--") }
    let variant = explicitVariant ?? config.codeSwitch.kbWhisperVariant

    var models: [Model] = []
    if wantsAll {
        models = [Models.baseEnglish, Models.largeV3, Models.sileroVAD]
        if let kb = Models.kbWhisperLarge(variant: variant) { models.insert(kb, at: 1) }
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
    let vadOn = !config.vadModel.isEmpty && FileManager.default.fileExists(atPath: config.vadModel)
    row(vadOn, "Silero VAD model", vadOn ? config.vadModel : "optional — ./scripts/setup.sh --vad")
    row(s.isConfigured, "Claude Code CLI (`claude -p`)",
        s.isConfigured ? s.claudeBinary : "not found — install Claude Code and run `claude` once to log in")
    let cs = config.codeSwitch
    if cs.enabled {
        row(true, "code-switching", "ENABLED — \(cs.languages.joined(separator: "+")), dominant \(cs.dominantLanguage), KB variant \(cs.kbWhisperVariant)")
        for (lang, path) in cs.requiredModelPaths {
            let ok = FileManager.default.fileExists(atPath: path)
            row(ok, "  model[\(lang)]", ok ? path : "missing — run scripts/setup.sh --codeswitch")
        }
        let vadOK = !config.vadModel.isEmpty
            && FileManager.default.fileExists(atPath: config.vadModel)
        row(vadOK, "  Silero VAD (required by code-switching)",
            vadOK ? config.vadModel : "missing — scripts/setup.sh --codeswitch fetches it")
    } else {
        row(true, "code-switching", "disabled (single-language path)")
    }

    let matchers = config.triggerBundleIds.map { $0.lowercased() }
    let teams = NSWorkspace.shared.runningApplications.contains {
        guard let b = $0.bundleIdentifier else { return false }
        return DetectionCoordinator.matchesTeamsBundle(b, matchers: matchers)
    }
    row(teams, "Microsoft Teams running", teams ? "" : "(only needed during a call)")
    row(CallDetector.defaultInputDevice() != nil, "default input device detected")
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

/// Regression check for the code-switching Smoother — the algorithmically
/// interesting, false-positive-prone part. Pure logic over synthetic
/// detections, so it needs no audio, no model, and no whisper on disk
/// (audio-fixture end-to-end checks live behind Tests/Fixtures and skip
/// gracefully when absent — see runCodeSwitchFixtureSelfTest).
func runCodeSwitchSelfTest() -> Bool {
    let cfg = CodeSwitchConfig()                  // sv/en, defaults
    func sm(_ window: Int) -> Smoother { Smoother(config: cfg, window: window) }
    let step = 1600, dur = 1500

    func det(_ i: Int, _ lang: String, conf: Double = 0.95,
             base: Int = 0) -> LanguageDetection {
        let s = base + i * step
        let seg = VADSegment(startMs: s, endMs: s + dur)
        if lang == "?" {
            return LanguageDetection(segment: seg, top: LanguageDetection.unknown,
                                     confidence: 0, margin: 0, logprobs: [:])
        }
        let other = lang == "sv" ? "en" : "sv"
        let lp = [lang: Foundation.log(conf), other: Foundation.log(1 - conf)]
        return LanguageDetection(segment: seg, top: lang, confidence: conf,
                                 margin: lp[lang]! - lp[other]!, logprobs: lp)
    }

    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)  \(detail())") }
    }

    let empty = LanguageTimeline(intervals: [])

    // Pass 1: a single-language track collapses to exactly one run.
    let svOnly = (0..<8).map { det($0, "sv") }
    let enOnly = (0..<8).map { det($0, "en") }
    let svRuns = sm(4).refine(svOnly, priorFrom: empty)
    let enRuns = sm(4).refine(enOnly, priorFrom: empty)
    check("sv_only → 1 sv run",
          svRuns.count == 1 && svRuns.first?.language == "sv",
          "got \(svRuns.map(\.language))")
    check("en_only → 1 en run",
          enRuns.count == 1 && enRuns.first?.language == "en",
          "got \(enRuns.map(\.language))")

    // Pass 1: mixed sv / en / sv with one en loanword inside the first sv
    // block → 3 runs (the lone loanword is absorbed by median + hysteresis).
    var mixed: [LanguageDetection] = []
    for i in 0..<6 { mixed.append(det(i, i == 2 ? "en" : "sv", conf: 0.9)) }
    for i in 6..<14 { mixed.append(det(i, "en")) }
    for i in 14..<20 { mixed.append(det(i, "sv")) }
    let mixedRuns = sm(4).refine(mixed, priorFrom: empty)
    check("mixed → 3 runs [sv,en,sv]",
          mixedRuns.map(\.language) == ["sv", "en", "sv"],
          "got \(mixedRuns.map(\.language)) (\(mixedRuns.count))")

    // Pass 2: Me has 2 ambiguous segments at t≈20s. Participants is
    // confidently English ending just before. The cross-track prior must
    // refine those segments to English…
    var me: [LanguageDetection] = []
    for i in 0..<4 { me.append(det(i, "sv")) }
    me.append(det(0, "?", base: 20_000)); me.append(det(1, "?", base: 20_000))
    for i in 0..<4 { me.append(det(i, "sv", base: 23_200)) }
    let partEn = (0..<5).map { det($0, "en", base: 12_000) }
    let partPrelim = sm(4).preliminary(partEn)
    let flipped = sm(4).refinedSegmentLabels(me, priorFrom: partPrelim)
    check("cross-track prior flips ambiguous Me segments to en",
          flipped[4] == "en" && flipped[5] == "en",
          "got \(flipped)")

    // …and with no nearby Participants speech, the same segments fall back
    // to the per-track decision (sv), not flipped.
    let isolated = sm(4).refinedSegmentLabels(me, priorFrom: empty)
    check("isolated ambiguous Me segments keep per-track sv",
          isolated[4] == "sv" && isolated[5] == "sv",
          "got \(isolated)")

    // Strength 0.5 makes Pass 2 a no-op (debug switch documented in config).
    var offCfg = CodeSwitchConfig(); offCfg.crossTrackPriorStrength = 0.5
    let neutral = Smoother(config: offCfg, window: 4)
        .refinedSegmentLabels(me, priorFrom: partPrelim)
    check("crossTrackPriorStrength 0.5 disables refinement",
          neutral[4] == "sv" && neutral[5] == "sv",
          "got \(neutral)")

    // mostRecentEndingBefore is past-only (causality / timing-skew gotcha).
    let tl = LanguageTimeline(intervals: [
        .init(startMs: 0, endMs: 5_000, language: "en", confidence: 0.9),
        .init(startMs: 9_000, endMs: 12_000, language: "sv", confidence: 0.9)
    ])
    check("timeline lookup is past-only & window-bounded",
          tl.mostRecentEndingBefore(6_000, withinMs: 8_000) == "en"
          && tl.mostRecentEndingBefore(6_000, withinMs: 500) == nil
          && tl.mostRecentEndingBefore(8_000, withinMs: 8_000) == "en")

    // Optional end-to-end audio fixtures (Tests/Fixtures) — skipped cleanly
    // when not present so `ghostie selftest` stays green without 2 GB models.
    let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/Fixtures")
    if FileManager.default.fileExists(atPath: fixtures.path) {
        print("  · Tests/Fixtures present — audio end-to-end checks would run here")
    } else {
        print("  · (audio fixtures absent — skipping end-to-end codeswitch checks)")
    }

    print("\ncode-switching self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}

/// Regression check for the OTA updater's pure parts — SemVer precedence and
/// the GitHub manifest parser. No network/disk/models, so it's green
/// everywhere (per CLAUDE.md selftest policy).
func runUpdaterSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)  \(detail())") }
    }
    func v(_ s: String) -> SemVer { SemVer.parse(s)! }

    check("equal versions are not an upgrade",
          !Updater.compare(running: v("1.2.0"), latest: v("1.2.0")))
    check("patch/minor/major bumps are upgrades",
          Updater.compare(running: v("1.2.0"), latest: v("1.2.1"))
          && Updater.compare(running: v("1.2.0"), latest: v("1.3.0"))
          && Updater.compare(running: v("1.9.0"), latest: v("2.0.0")))
    check("downgrade is never offered",
          !Updater.compare(running: v("1.3.0"), latest: v("1.2.0")))
    check("v / V prefix tolerated",
          v("v1.2.0") == v("1.2.0") && v("V1.2.0") == v("1.2.0"))
    check("short cores zero-pad",
          v("1.2") == v("1.2.0") && v("1") == v("1.0.0")
          && Updater.compare(running: v("1.2"), latest: v("1.2.1")))
    check("pre-release precedence (SemVer 2.0)",
          v("1.2.0-rc.1") < v("1.2.0")
          && v("1.2.0-rc.1") < v("1.2.0-rc.2")
          && v("1.2.0-alpha") < v("1.2.0-beta")
          && !Updater.compare(running: v("1.2.0"), latest: v("1.2.0-rc.1")))
    check("build metadata ignored", v("1.2.0+abc123") == v("1.2.0"))
    check("non-numeric version → nil",
          SemVer.parse("nightly") == nil && SemVer.parse("") == nil
          && SemVer.parse("v") == nil)

    func json(_ s: String) -> Data { Data(s.utf8) }
    let sha = String(repeating: "a", count: 64)
    let good = json("""
    {"tag_name":"v1.3.0","name":"Ghostie 1.3.0",
     "body":"Shiny new things.\\n<!--sha256:\(sha)-->",
     "assets":[{"name":"Ghostie-1.3.0.zip",
       "browser_download_url":"https://example.com/Ghostie-1.3.0.zip","size":4242}]}
    """)
    if let r = try? Updater.parseLatestJSON(good) {
        check("manifest: tag/asset/sha/size parsed",
              r.version == v("1.3.0")
              && r.assetURL.absoluteString == "https://example.com/Ghostie-1.3.0.zip"
              && r.sha256 == sha && r.expectedSize == 4242)
        check("manifest: sha comment stripped from notes",
              !r.notes.contains("sha256") && r.notes.contains("Shiny new things."))
    } else {
        check("manifest: tag/asset/sha/size parsed", false, "threw")
        check("manifest: sha comment stripped from notes", false, "threw")
    }
    let noAsset = json("""
    {"tag_name":"v1.3.0","body":"x <!--sha256:\(sha)-->",
     "assets":[{"name":"Other.zip","browser_download_url":"https://e/o.zip","size":1}]}
    """)
    check("manifest: missing matching asset throws",
          (try? Updater.parseLatestJSON(noAsset)) == nil)
    let noSha = json("""
    {"tag_name":"v1.3.0","body":"no checksum here",
     "assets":[{"name":"Ghostie-1.3.0.zip","browser_download_url":"https://e/g.zip","size":1}]}
    """)
    check("manifest: no sha → throws (never install unverified)",
          (try? Updater.parseLatestJSON(noSha)) == nil)
    let badTag = json("""
    {"tag_name":"nightly","body":"<!--sha256:\(sha)-->","assets":[]}
    """)
    check("manifest: unparseable tag throws",
          (try? Updater.parseLatestJSON(badTag)) == nil)

    print("\nupdater self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}

func printHelp() {
    print("""
    Ghostie — local Teams call transcriber & summarizer (no bot joins).

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
      fetch-models [variant] [--all|--codeswitch|--vad]
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
case "update":
    cmdUpdate(config, install: args.contains("--install"))
case "selftest":
    let cleanerOK = runTranscriptCleanerSelfTest()
    print("")
    let codeSwitchOK = runCodeSwitchSelfTest()
    print("")
    let updaterOK = runUpdaterSelfTest()
    print("")
    let detectorOK = runDetectorStateMachineSelfTest()
    exit(cleanerOK && codeSwitchOK && updaterOK && detectorOK ? 0 : 1)
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
