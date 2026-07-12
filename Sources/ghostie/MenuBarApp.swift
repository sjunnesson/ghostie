import AppKit
import UserNotifications

/// The menu bar (status bar) application. No Dock icon — it lives entirely in
/// the macOS menu header for quick access.
final class MenuBarApp: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let engine: Engine
    /// Always the engine's live config, so menu actions reflect Settings edits.
    private var config: Config { engine.config }
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var statusMenuItem: NSMenuItem!
    private var axWarningItem: NSMenuItem!
    private var backlogItem: NSMenuItem!
    private var lastEventItem: NSMenuItem!
    private var toggleItem: NSMenuItem!
    private var lastNoteItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    /// UNUserNotificationCenter grant. When denied, every async signal
    /// ("Call summarized", "Update available") would silently vanish — the
    /// disabled "Last:" menu line below is the always-visible fallback.
    private var notificationsAllowed = true
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
        CrashBreadcrumb.install()

        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { [weak self] granted, _ in
                DispatchQueue.main.async { self?.notificationsAllowed = granted }
                if !granted {
                    Log.warn("Notifications are denied — call/update events will only appear in the menu's 'Last:' line. Grant in System Settings ▸ Notifications ▸ Ghostie.")
                }
            }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Self.menuBarIcon

        buildMenu()
        statusItem.menu = menu
        menu.delegate = self

        engine.onStateChange = { [weak self] st in
            DispatchQueue.main.async { self?.render(st) }
        }
        engine.onNote = { [weak self] note in
            DispatchQueue.main.async {
                self?.notify("Call summarized", note.lastPathComponent)
                self?.refreshLastNote()
            }
        }
        engine.onBacklogChange = { [weak self] pending in
            // Full backlog detail lives in Settings → Notes → Advanced, but a
            // user whose calls keep failing (never logged into `claude`, say)
            // used to see a normal-looking ghost and nothing else — surface a
            // lightweight one-line indicator in the menu.
            DispatchQueue.main.async {
                self?.updateBacklogItem(pending: pending)
                self?.refreshLastNote()
            }
        }

        engine.startListening()
        render(engine.state)

        // First-ever launch: one native primer so a new user knows what to
        // expect (permission prompts on the first call, the model download)
        // before anything silently happens. Marker-gated; never repeats.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.showOnboardingIfNeeded()
        }

        // First-launch / missing-model nudge: the speech model is no longer
        // bundled in the .dmg (~140 MB saved), so a fresh install needs to
        // download it from Hugging Face on first run. Open Settings to the
        // Transcription pane and auto-start the download. No-op if every
        // required model is already on disk.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.openSettingsIfModelsMissing()
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

        // Backlog indicator: hidden at zero; one line + one click to drain.
        backlogItem = NSMenuItem(title: "", action: #selector(processBacklogNow),
                                 keyEquivalent: "")
        backlogItem.target = self
        backlogItem.isHidden = true
        menu.addItem(backlogItem)

        // Always-visible record of the last event, notification grant or not.
        lastEventItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        lastEventItem.isEnabled = false
        lastEventItem.isHidden = true
        menu.addItem(lastEventItem)

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

    /// AX permission can be revoked at any moment via System Settings, but
    /// the warning row is only visible inside the menu — so re-checking when
    /// the menu opens is exactly as fresh as the user can perceive, and it
    /// keeps `AXIsProcessTrusted()` (a TCC round-trip) off any timer.
    func menuWillOpen(_ menu: NSMenu) {
        axWarningItem.isHidden = AXIsProcessTrusted()
        // Cheap (one directory listing when empty); keeps the indicator
        // honest even if a drain happened outside onBacklogChange.
        updateBacklogItem(pending: Backlog.pendingCount)
    }

    private func updateBacklogItem(pending: Int) {
        backlogItem.isHidden = pending == 0
        if pending > 0 {
            backlogItem.title = "⏳ \(pending) call\(pending == 1 ? "" : "s") queued — Process Now"
        }
    }

    @objc private func processBacklogNow() {
        engine.drainBacklog()
    }

    /// Transparent 1×1 placeholder. Assigning this as a menu item's image
    /// overrides macOS Sonoma+'s auto-attached glyphs (the gear that gets
    /// stuck onto the Settings… item via title + `,` heuristics). `image =
    /// nil` leaves the system glyph in place; an explicit empty NSImage
    /// wins.
    private static let blankIcon: NSImage = {
        let img = NSImage(size: NSSize(width: 1, height: 1))
        img.lockFocus(); img.unlockFocus()
        return img
    }()

    private func item(_ title: String, _ sel: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
        i.target = self
        i.image = Self.blankIcon
        return i
    }

    /// Rendered once and reused. The ghost shape never changes — only the
    /// tint conveys state — so rebuilding the Bezier image and reassigning
    /// `statusItem.button?.image` on every render (as we used to) just forced
    /// a pointless WindowServer invalidation each time. Kept as a template so
    /// `contentTintColor` actually applies — without that the menu-bar
    /// button falls back to the raw black pixels we draw in
    /// `GhostIcon.menuBarImage()`, which were invisible on a dark menu
    /// bar when state was `.processing` (orange tint never took effect).
    private static let menuBarIcon: NSImage = {
        let img = GhostIcon.menuBarImage()
        img.isTemplate = true
        return img
    }()
    /// Last tint actually pushed to the button, so per-second renders while
    /// recording don't re-assign an unchanged tint. `nil` matches the
    /// button's initial state (no tint → adapts to the menu bar).
    private var appliedTint: NSColor?

    private func render(_ state: EngineState) {
        var title = "● " + state.menuLabel
        if case .recording(let since) = state {
            let secs = Int(Date().timeIntervalSince(since))
            title = String(format: "● Recording call… %02d:%02d", secs / 60, secs % 60)
        }
        statusMenuItem.title = title
        toggleItem.title = engine.isListening ? "Pause Listening" : "Resume Listening"

        // Always the ghost; its tint conveys state. The image itself is set
        // once at launch (`menuBarIcon`) and never reassigned.
        let color: NSColor? = {
            switch state {
            case .recording:  return .systemRed
            case .processing: return .systemOrange
            case .watching:   return nil               // adapts to menu bar
            case .paused:     return .tertiaryLabelColor
            }
        }()
        if color != appliedTint {
            statusItem.button?.contentTintColor = color
            appliedTint = color
        }

        syncTick(for: state)
    }

    /// The 1 Hz tick exists solely to advance the "Recording call… MM:SS"
    /// title, so it runs only while `.recording` — in every other state we
    /// render on engine callbacks instead of polling, letting App Nap do its
    /// thing. Called from `render` (always on the main thread), so a rapid
    /// record/stop flap can't double-start or leak: the `tick == nil` guard
    /// and the invalidate below are serialized.
    private func syncTick(for state: EngineState) {
        if case .recording = state {
            guard tick == nil else { return }
            // Scheduled on `.common` mode (not the default `.default`-only
            // mode that `Timer.scheduledTimer` uses) so the title keeps
            // ticking while the menu is open — NSMenu tracking runs the
            // runloop in `.eventTracking`, which `.common` includes.
            let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                guard let self else { return }
                self.render(self.engine.state)
            }
            RunLoop.main.add(t, forMode: .common)
            tick = t
        } else {
            tick?.invalidate()
            tick = nil
        }
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
        ensureSettings().show()
    }

    private func ensureSettings() -> SettingsWindow {
        if let s = settings { return s }
        let s = SettingsWindow(engine: engine) { [weak self] newConfig in
            guard let self else { return }
            self.engine.applyConfig(newConfig)
            self.render(self.engine.state)
            self.refreshLastNote()
            self.notify("Ghostie", "Settings saved.")
        }
        settings = s
        return s
    }

    private func openSettingsIfModelsMissing() {
        let required = Models.required(for: engine.config)
        let anyMissing = required.contains { m in
            // verifyHash: false — this is a launch-time "is it present?"
            // probe; full SHA-256 of ~GBs of models doesn't belong here.
            if case .missing = ModelDownloader.health(for: [m], verifyHash: false)[0].state { return true }
            return false
        }
        guard anyMissing else { return }
        ensureSettings().showOnTranscriptionForMissingModels()
    }


    @objc private func quit() {
        statusMenuItem.title = "Finishing up…"
        tick?.invalidate(); tick = nil
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

    // MARK: First-run primer

    private static let onboardedMarker = "\(NSHomeDirectory())/.ghostie/.onboarded"

    private func showOnboardingIfNeeded() {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: Self.onboardedMarker) else { return }
        try? fm.createDirectory(atPath: "\(NSHomeDirectory())/.ghostie",
                                withIntermediateDirectories: true)
        fm.createFile(atPath: Self.onboardedMarker, contents: Data())

        let alert = NSAlert()
        alert.messageText = "Welcome to Ghostie"
        alert.informativeText = """
        Ghostie sits in your menu bar and listens for Microsoft Teams calls — \
        no bot ever joins the meeting. Calls are recorded and transcribed \
        entirely on this Mac, then summarized into a markdown note.

        Two one-time things to know:

        • On your first call, macOS will ask for Microphone and Screen \
        Recording access — grant both, and it sticks.

        • Ghostie needs a speech model (~140 MB, fetched from Hugging Face). \
        Settings can start that download now.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { openSettings() }
    }

    private static let eventClock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()

    private func notify(_ title: String, _ body: String) {
        // The menu line updates regardless of the notification grant, so a
        // user who denied notifications still has somewhere to see events.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.lastEventItem.title = "Last: \(title) · \(Self.eventClock.string(from: Date()))"
            self.lastEventItem.isHidden = false
        }
        guard notificationsAllowed else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(
            identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

}
