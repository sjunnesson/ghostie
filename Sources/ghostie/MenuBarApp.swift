import AppKit
import ServiceManagement

/// The menu bar (status bar) application. No Dock icon — it lives entirely in
/// the macOS menu header for quick access.
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private let engine: Engine
    /// Always the engine's live config, so menu actions reflect Settings edits.
    private var config: Config { engine.config }
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusMenuItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var lastNoteItem: NSMenuItem!
    private var loginItem: NSMenuItem!
    private var tick: Timer?
    private var settings: SettingsWindow?

    init(config: Config) {
        self.engine = Engine(config: config)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar agent, no Dock icon

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = GhostIcon.menuBarImage()

        buildMenu()
        statusItem.menu = menu

        engine.onStateChange = { [weak self] st in
            DispatchQueue.main.async { self?.render(st) }
        }
        engine.onNote = { [weak self] note in
            DispatchQueue.main.async {
                self?.notify("Call summarized", note.lastPathComponent)
                self?.refreshLastNote()
            }
        }

        engine.startListening()
        render(engine.state)

        // Refresh the recording timer label every second.
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if case .recording = self.engine.state { self.render(self.engine.state) }
        }
    }

    // MARK: Menu

    private func buildMenu() {
        statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        toggleItem = item("Pause Listening", #selector(toggleListening))
        menu.addItem(toggleItem)

        menu.addItem(item("Open Notes Folder", #selector(openNotesFolder)))
        lastNoteItem = item("Open Last Summary", #selector(openLastNote))
        lastNoteItem.isEnabled = false
        menu.addItem(lastNoteItem)
        menu.addItem(item("Run 15-Second Test", #selector(runTest)))
        menu.addItem(.separator())

        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Diagnostics", #selector(showDiagnostics)))
        loginItem = item("Start at Login", #selector(toggleLogin))
        menu.addItem(loginItem)
        menu.addItem(.separator())

        menu.addItem(item("About Ghostie", #selector(showAbout)))
        menu.addItem(item("Quit Ghostie", #selector(quit), key: "q"))

        refreshLastNote()
        refreshLoginState()
    }

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        return i
    }

    private func render(_ state: EngineState) {
        var title = "● " + state.menuLabel
        if case .recording(let since) = state {
            let secs = Int(Date().timeIntervalSince(since))
            title = String(format: "● Recording call… %02d:%02d", secs / 60, secs % 60)
        }
        statusMenuItem.title = title
        toggleItem.title = engine.isListening ? "Pause Listening" : "Resume Listening"

        // Always the ghost; its tint conveys state.
        let color: NSColor? = {
            switch state {
            case .recording:  return .systemRed
            case .processing: return .systemOrange
            case .watching:   return nil               // adapts to menu bar
            case .paused:     return .tertiaryLabelColor
            }
        }()
        let img = GhostIcon.menuBarImage()
        img.isTemplate = (color == nil)
        statusItem.button?.image = img
        statusItem.button?.contentTintColor = color
    }

    private func refreshLastNote() {
        if let n = engine.lastNote {
            lastNoteItem.isEnabled = true
            lastNoteItem.title = "Open Last Summary (\(n.deletingPathExtension().lastPathComponent))"
        } else if let latest = mostRecentNote() {
            engineLastNoteFallback = latest
            lastNoteItem.isEnabled = true
            lastNoteItem.title = "Open Last Summary"
        }
    }
    private var engineLastNoteFallback: URL?

    // MARK: Actions

    @objc private func toggleListening() {
        engine.isListening ? engine.stopListening() : engine.startListening()
        render(engine.state)
    }

    @objc private func openNotesFolder() {
        let f = URL(fileURLWithPath: config.notesFolder)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        NSWorkspace.shared.open(f)
    }

    @objc private func openLastNote() {
        if let n = engine.lastNote ?? engineLastNoteFallback ?? mostRecentNote() {
            NSWorkspace.shared.open(n)
        }
    }

    @objc private func runTest() {
        notify("Ghostie", "Recording a 15-second test — speak and play some audio.")
        engine.runTest(seconds: 15) { [weak self] note in
            DispatchQueue.main.async {
                self?.refreshLastNote()
                if let note { NSWorkspace.shared.open(note) }
            }
        }
    }

    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsWindow { [weak self] newConfig in
                guard let self else { return }
                self.engine.applyConfig(newConfig)
                self.render(self.engine.state)
                self.refreshLastNote()
                self.notify("Ghostie", "Settings saved.")
            }
        }
        settings?.show()
    }

    @objc private func showDiagnostics() {
        let t = Transcriber(config: config)
        let s = Summarizer(config: config)
        let lines = [
            "Transcription: \(t.isAvailable ? "ready (local whisper.cpp)" : "NOT set up — run scripts/setup.sh")",
            "Summaries: \(s.isConfigured ? "claude -p (\(config.summaryModel))" : "Claude Code CLI not found — run `claude` once to log in")",
            "Whisper model: \(config.whisperModel)",
            "Notes folder: \(config.notesFolder)",
            "Config: \(Config.configPath)",
            "Log: \(NSHomeDirectory())/.ghostie/ghostie.log",
            "",
            "Screen Recording + Microphone permission are requested on the first",
            "recording. Grant them to Ghostie in System Settings ▸",
            "Privacy & Security, then start a call."
        ]
        let alert = NSAlert()
        alert.messageText = "Ghostie Diagnostics"
        alert.informativeText = lines.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Open Privacy Settings")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    @objc private func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify("Ghostie", "Could not change login item: \(error.localizedDescription)")
        }
        refreshLoginState()
    }

    private func refreshLoginState() {
        guard #available(macOS 13.0, *) else { loginItem.isHidden = true; return }
        loginItem.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Ghostie"
        alert.informativeText = """
        Listens to your Microsoft Teams calls locally — no bot ever joins the \
        meeting — then transcribes (locally) and summarizes each call to markdown.

        Calls processed this session: \(engine.callsProcessed)
        """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        statusMenuItem.title = "Finishing up…"
        engine.shutdown { DispatchQueue.main.async { NSApp.terminate(nil) } }
    }

    // MARK: Helpers

    private func mostRecentNote() -> URL? {
        let folder = URL(fileURLWithPath: config.notesFolder)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files
            .filter { $0.pathExtension == "md" && !$0.lastPathComponent.contains("_transcript") }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return a > b
            }
            .first
    }

    private func notify(_ title: String, _ body: String) {
        let n = NSUserNotification()
        n.title = title
        n.informativeText = body
        NSUserNotificationCenter.default.deliver(n)
    }

}
