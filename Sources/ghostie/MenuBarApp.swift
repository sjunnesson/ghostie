import AppKit
import UserNotifications

/// The menu bar (status bar) application. No Dock icon — it lives entirely in
/// the macOS menu header for quick access.
final class MenuBarApp: NSObject, NSApplicationDelegate {
    private let engine: Engine
    /// Always the engine's live config, so menu actions reflect Settings edits.
    private var config: Config { engine.config }
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusMenuItem: NSMenuItem!
    private var axWarningItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var lastNoteItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var tick: Timer?
    private var settings: SettingsWindow?
    private let updater = Updater()
    private var updateTimer: DispatchSourceTimer?
    private var availableRelease: ReleaseInfo?
    private var lastNotifiedTag: String?

    init(config: Config) {
        self.engine = Engine(config: config)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory) // menu bar agent, no Dock icon

        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { _, _ in }

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
        engine.onBacklogChange = { [weak self] _ in
            // Backlog count is surfaced in Settings → Notes → Advanced; the
            // menu no longer carries a counter, but we still keep the
            // last-note state in sync after a drain.
            DispatchQueue.main.async { self?.refreshLastNote() }
        }

        engine.startListening()
        render(engine.state)

        // Refresh the recording timer + AX warning visibility every second.
        // AX permission can be revoked at any moment via System Settings, so
        // the warning must follow on its own cadence rather than only on
        // engine state changes.
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.render(self.engine.state)
        }

        // OTA: a delayed launch check + a daily timer (only on builds we can
        // cryptographically verify; the timer re-reads the toggle each fire).
        if Updater.runningBuildSupportsOTA() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
                self?.maybeAutoCheck()
            }
            let ut = DispatchSource.makeTimerSource(
                queue: DispatchQueue(label: "ghostie.updatecheck"))
            ut.schedule(deadline: .now() + 86_400, repeating: 86_400)
            ut.setEventHandler { [weak self] in
                DispatchQueue.main.async { self?.maybeAutoCheck() }
            }
            ut.resume()
            updateTimer = ut
        }
    }

    // MARK: Menu

    private func buildMenu() {
        statusMenuItem = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        // AX denial warning. Hidden when permission is granted; clicking opens
        // the relevant System Settings pane so the user can grant in one step.
        axWarningItem = NSMenuItem(
            title: "⚠︎ Accessibility off — meeting-window signal disabled",
            action: #selector(openAccessibilitySettings), keyEquivalent: "")
        axWarningItem.target = self
        axWarningItem.isHidden = true
        menu.addItem(axWarningItem)

        menu.addItem(.separator())

        // Trimmed menu: only the actions that make sense from the menu bar
        // itself live here. Anything tied to configuration, diagnostics, the
        // backlog, login-at-startup or version info moved into Settings.
        toggleItem = item("Pause Listening", #selector(toggleListening))
        menu.addItem(toggleItem)

        lastNoteItem = item("Open Last Summary", #selector(openLastNote))
        lastNoteItem.isEnabled = false
        menu.addItem(lastNoteItem)
        menu.addItem(item("Run 30-Second Test", #selector(runTest)))
        menu.addItem(.separator())

        updateItem = item("Check for Updates…", #selector(checkForUpdatesManually))
        menu.addItem(updateItem)
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())

        menu.addItem(item("Quit Ghostie", #selector(quit), key: "q"))

        refreshLastNote()
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
        // AX permission state can change at any moment via System Settings; we
        // re-check on every render so revocation surfaces within a second.
        axWarningItem.isHidden = AXIsProcessTrusted()

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

    @objc private func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    @objc private func openLastNote() {
        if let n = engine.lastNote ?? engineLastNoteFallback ?? mostRecentNote() {
            NSWorkspace.shared.open(n)
        }
    }

    @objc private func runTest() {
        notify("Ghostie", "Recording a 30-second test — speak and play some audio.")
        engine.runTest(seconds: 30) { [weak self] note in
            DispatchQueue.main.async {
                self?.refreshLastNote()
                if let note { NSWorkspace.shared.open(note) }
            }
        }
    }

    @objc private func openSettings() {
        if settings == nil {
            settings = SettingsWindow(engine: engine) { [weak self] newConfig in
                guard let self else { return }
                self.engine.applyConfig(newConfig)
                self.render(self.engine.state)
                self.refreshLastNote()
                self.notify("Ghostie", "Settings saved.")
            }
        }
        settings?.show()
    }


    @objc private func quit() {
        statusMenuItem.title = "Finishing up…"
        updateTimer?.cancel(); updateTimer = nil
        engine.shutdown { DispatchQueue.main.async { NSApp.terminate(nil) } }
    }

    // MARK: Updates

    /// Background launch/daily check: throttled, silent on failure, fires a
    /// single notification per new version.
    private func maybeAutoCheck() {
        guard Updater.runningBuildSupportsOTA() else { return }
        let cfg = Config.loadRaw()
        guard cfg.autoCheckUpdates else { return }
        if Date().timeIntervalSince(cfg.lastUpdateCheck) < 24 * 3600 { return }
        updater.check(config: config) { [weak self] result in
            if case .success(.available(let r, _)) = result {
                self?.surfaceUpdate(r, notifyUser: true)
            }
        }
    }

    private func surfaceUpdate(_ r: ReleaseInfo, notifyUser: Bool) {
        availableRelease = r
        updateItem.title = "Update to \(r.tag)…"
        updateItem.action = #selector(installUpdate)
        if notifyUser && lastNotifiedTag != r.tag {
            lastNotifiedTag = r.tag
            notify("Ghostie update available",
                   "Version \(r.tag) is ready — choose “Update to \(r.tag)…” from the menu.")
        }
    }

    @objc private func checkForUpdatesManually() {
        if let r = availableRelease { promptInstall(r); return }
        updateItem.isEnabled = false
        let prevTitle = updateItem.title
        updateItem.title = "Checking for updates…"
        updater.check(config: config) { [weak self] result in
            guard let self else { return }
            self.updateItem.isEnabled = true
            switch result {
            case .success(.available(let r, _)):
                self.surfaceUpdate(r, notifyUser: false)
                self.promptInstall(r)
            case .success(.upToDate(let cur)):
                self.updateItem.title = prevTitle
                self.infoAlert("You're up to date",
                               "Ghostie \(cur) is the latest version.")
            case .success(.skippedUnsupportedBuild):
                self.updateItem.title = prevTitle
                self.unsupportedBuildAlert()
            case .failure(let e):
                self.updateItem.title = prevTitle
                self.infoAlert("Update check failed", e.localizedDescription)
            }
        }
    }

    @objc private func installUpdate() {
        guard let r = availableRelease else { return }
        promptInstall(r)
    }

    private func promptInstall(_ r: ReleaseInfo) {
        let a = NSAlert()
        a.messageText = "Update Ghostie to \(r.tag)?"
        a.informativeText = (r.notes.isEmpty ? "" : r.notes + "\n\n")
            + "Ghostie will download and verify the update, then quit and "
            + "relaunch. It won't interrupt an active call."
        a.addButton(withTitle: "Update Now")
        a.addButton(withTitle: "Later")
        NSApp.activate(ignoringOtherApps: true)
        guard a.runModal() == .alertFirstButtonReturn else { return }
        startInstall(r)
    }

    private func startInstall(_ r: ReleaseInfo) {
        if updater.isRunning { return }
        updateItem.isEnabled = false
        updateItem.title = "Downloading \(r.tag)…"
        updater.downloadAndInstall(r, engine: engine,
            status: { [weak self] s in self?.updateItem.title = s },
            finish: { [weak self] err in
                guard let self else { return }
                self.updateItem.isEnabled = true
                self.updateItem.title = "Update to \(r.tag)…"
                if let err {
                    self.infoAlert("Update failed", err.localizedDescription)
                }
            },
            commit: { [weak self] in
                guard let self else { return }
                self.statusMenuItem.title = "Updating…"
                self.engine.shutdown {
                    DispatchQueue.main.async { NSApp.terminate(nil) }
                }
            })
    }

    private func unsupportedBuildAlert() {
        let a = NSAlert()
        a.messageText = "Automatic updates unavailable"
        a.informativeText = "This build isn't a notarized release, so it "
            + "can't verify and self-update. Download the latest from GitHub "
            + "Releases."
        a.addButton(withTitle: "Open Releases")
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(Updater.releasesPage)
        }
    }

    private func infoAlert(_ title: String, _ info: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = info
        a.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
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
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

}
