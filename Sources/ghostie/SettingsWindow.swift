import AppKit
import AVFoundation
import ServiceManagement
import QuartzCore

/// A real Settings window in the System-Settings-14+ style: 220 pt sidebar with
/// a brand row and grouped nav, content panes that crossfade on selection, and
/// status badges that surface where each knob actually lives. The behavioural
/// contract (Config keys read, `onSave` callback, engine update path) is the
/// same as the legacy NSTabView form this replaces.
final class SettingsWindow: NSObject, NSWindowDelegate {

    // MARK: Public API (unchanged)

    init(engine: Engine? = nil, onSave: @escaping (Config) -> Void) {
        self.engine = engine
        self.onSave = onSave
        super.init()
    }
    var onClose: (() -> Void)?

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            refreshLiveBits()
            return
        }
        rebuildWindow()
    }

    /// First-launch entry point used by MenuBarApp when a required model is
    /// missing locally. Opens to the Transcription pane and auto-starts the
    /// first missing download so the user sees progress immediately rather
    /// than hunting for the right button. Subsequent missing models keep
    /// their manual Download buttons (the downloader processes one at a time
    /// and the per-row UI tracks inflight by key).
    func showOnTranscriptionForMissingModels() {
        if window == nil {
            currentPaneId = .transcription
            show()
        } else {
            show()
            select(.transcription, animated: false)
        }
        DispatchQueue.main.async { [weak self] in
            self?.startFirstMissingRequiredDownload()
        }
    }

    private func startFirstMissingRequiredDownload() {
        guard inflightModelKey == nil else { return }
        for m in Models.required(for: cfg) {
            guard let key = rowKey(for: m) else { continue }
            if case .missing = ModelDownloader.health(for: [m])[0].state {
                startDownload(m, key: key)
                return
            }
        }
    }

    private func rowKey(for model: Model) -> String? {
        switch model.filename {
        case Models.baseEnglish.filename: return "base"
        case Models.sileroVAD.filename:   return "vad"
        case Models.largeV3.filename:     return "large-v3"
        default:
            if let kb = Models.kbWhisperLarge(variant: cfg.codeSwitch.kbWhisperVariant),
               model.filename == kb.filename { return "kb" }
            return nil
        }
    }

    // MARK: Stored references

    private weak var engine: Engine?
    private let onSave: (Config) -> Void
    private var window: NSWindow?
    /// The size the user picked (initially the default 1000x920, updated on
    /// every interactive corner drag). `windowWillResize` clamps any
    /// non-live-resize request back to this so internal autolayout passes
    /// can't grow or shrink the window when switching panes.
    private var lockedContentSize = NSSize(width: 900, height: 820)

    private var cfg = Config.loadRaw()                // working copy
    private var currentPaneId: PaneId = .listening
    private let downloader = ModelDownloader()
    private let updater = Updater()

    /// `inflightModelKey` is set while a per-row download is running so the
    /// other rows disable their action buttons without a global "everything
    /// disabled" pass.
    private var inflightModelKey: String?

    private struct PaneRefs {
        var listening: ListeningPane?
        var notes: NotesPane?
        var transcription: TranscriptionPane?
        var summary: SummaryPane?
        var updates: UpdatesPane?
        var advanced: AdvancedPane?
        var about: AboutPane?
    }
    private var panes = PaneRefs()
    private var sidebar: Sidebar?
    /// Retained so its view stays alive while we use it as the window's
    /// contentView. `NSWindow.contentViewController` would re-derive the
    /// window's contentSize from this controller's preferredContentSize and
    /// its children's intrinsic sizes — which is exactly the auto-resize on
    /// pane switch we want to avoid.
    private var split: NSSplitViewController?
    private var contentContainer: NSView?
    private var toolbarBadge: StatusBadgeView?

    /// Ticks the sidebar's "Recording · MM:SS" label while the window is
    /// open. The engine only fires `onStateChange` at transitions, so the
    /// MM:SS would otherwise stay frozen at the moment recording started.
    /// ListeningPane has its own tick for its big tile; this one is just for
    /// the sidebar (always visible regardless of selected pane).
    private var sidebarTick: Timer?

    // MARK: Window construction

    private func rebuildWindow() {
        cfg = Config.loadRaw()

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 820),
            styleMask: [.titled, .closable, .miniaturizable,
                        .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        win.title = "Ghostie Settings"
        win.titleVisibility = .hidden
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = false
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.minSize = NSSize(width: 800, height: 560)

        let split = NSSplitViewController()
        // The split view's NSSplitView has its own divider; we render our own
        // borders on the sidebar and content backgrounds, so suppress the
        // platform divider line entirely.
        split.splitView.dividerStyle = .thin

        // ---- Sidebar -----------------------------------------------------
        let side = Sidebar(
            paneOrder: PaneId.mainOrder,
            paneBottom: PaneId.bottomOrder,
            initialPane: currentPaneId,
            engine: engine,
            onSelect: { [weak self] id in self?.select(id) })
        self.sidebar = side
        let sideVC = NSViewController()
        sideVC.view = side
        let sideItem = NSSplitViewItem(sidebarWithViewController: sideVC)
        sideItem.minimumThickness = 220
        sideItem.maximumThickness = 220
        sideItem.canCollapse = false
        sideItem.holdingPriority = .init(260)
        split.addSplitViewItem(sideItem)

        // ---- Content -----------------------------------------------------
        let contentVC = NSViewController()
        let content = NSView()
        contentVC.view = content
        let contentItem = NSSplitViewItem(viewController: contentVC)
        contentItem.minimumThickness = 480
        split.addSplitViewItem(contentItem)

        // Thin toolbar strip. Visually invisible (no title text, no tinted
        // background, no hairline) so the sidebar/content seam runs cleanly
        // from the title bar all the way down. The strip is still kept as a
        // 38 pt high slot so the traffic lights have a drag region and the
        // recording badge has somewhere to sit when a call is live.
        let toolbar = ThemedLayerView()
        toolbar.themeApply = { $0.layer?.backgroundColor = Theme.contentBg.cgColor }
        let toolbarBadge = StatusBadgeView(kind: .danger, label: "Recording")
        toolbarBadge.translatesAutoresizingMaskIntoConstraints = false
        toolbarBadge.isHidden = true

        toolbar.addSubview(toolbarBadge)
        self.toolbarBadge = toolbarBadge

        // Container for pane bodies (scroll view swapped on selection).
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        self.contentContainer = container

        content.addSubview(toolbar)
        content.addSubview(container)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: content.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: 38),

            toolbarBadge.trailingAnchor.constraint(equalTo: toolbar.trailingAnchor, constant: -18),
            toolbarBadge.centerYAnchor.constraint(equalTo: toolbar.centerYAnchor),

            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])

        // Use the split view as the window's contentView directly (rather
        // than `win.contentViewController = split`). The contentViewController
        // path makes NSWindow listen to the controller's preferredContentSize
        // and recompute its own contentSize on every pane swap, which is what
        // was making the window grow on Listening and shrink on Updates.
        // Going via contentView decouples the window's size from anything
        // happening inside the panes — the user is the only thing that can
        // resize it.
        self.split = split
        let splitView = split.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView(frame: NSRect(origin: .zero,
                                         size: NSSize(width: 900, height: 820)))
        host.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: host.topAnchor),
            splitView.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            splitView.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        win.contentView = host
        self.window = win
        select(currentPaneId, animated: false)
        win.center()
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
        wireEngineObserver()
        startSidebarTick()
    }

    private func startSidebarTick() {
        sidebarTick?.invalidate()
        // `.common` mode (not the default `.default`-only mode that
        // `Timer.scheduledTimer` installs) so the tick keeps firing when the
        // window isn't key — e.g. user clicks into another app while the
        // Settings window is still visible on screen.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let engine = self.engine else { return }
            if case .recording = engine.state {
                self.sidebar?.refreshStatus(engine.state, perms: PermissionsState.current)
            }
        }
        RunLoop.main.add(t, forMode: .common)
        sidebarTick = t
    }

    /// Block any resize that isn't the user dragging the corner handle.
    /// `inLiveResize` is true only during an active interactive drag, so a
    /// programmatic `setFrame:` from NSSplitViewController's internal sizing
    /// passes lands here with `inLiveResize == false` and gets snapped back.
    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        if sender.inLiveResize { return frameSize }
        // Translate the locked content size back into a frame size, including
        // the title bar height.
        let dummy = NSRect(origin: .zero,
                            size: NSSize(width: lockedContentSize.width,
                                          height: lockedContentSize.height))
        return sender.frameRect(forContentRect: dummy).size
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        // The user finished dragging — record the new size so subsequent
        // programmatic resize attempts get clamped to it instead of the
        // original default.
        if let win = window {
            lockedContentSize = win.contentRect(forFrameRect: win.frame).size
        }
    }

    func windowWillClose(_ notification: Notification) {
        downloader.cancel()
        updater.cancel()
        unwireEngineObserver()
        sidebarTick?.invalidate(); sidebarTick = nil
        window = nil
        sidebar = nil
        split = nil
        contentContainer = nil
        toolbarBadge = nil
        panes = PaneRefs()
        onClose?()
    }

    /// Re-evaluate permissions / engine state / model rows when the user comes
    /// back from System Settings or just clicks into the window.
    func windowDidBecomeKey(_ notification: Notification) {
        refreshLiveBits()
    }

    private func refreshLiveBits() {
        panes.listening?.refreshPermissions()
        panes.listening?.refreshLiveStatus(engine?.state ?? .paused)
        panes.transcription?.refreshAllRows()
        sidebar?.refreshStatus(engine?.state ?? .paused, perms: PermissionsState.current)
    }

    // MARK: Engine observer

    private var oldEngineHandler: ((EngineState) -> Void)?
    private func wireEngineObserver() {
        guard let engine else { return }
        oldEngineHandler = engine.onStateChange
        engine.onStateChange = { [weak self, oldHandler = oldEngineHandler] st in
            oldHandler?(st)
            DispatchQueue.main.async { self?.engineStateChanged(st) }
        }
    }
    private func unwireEngineObserver() {
        guard let engine else { return }
        engine.onStateChange = oldEngineHandler
        oldEngineHandler = nil
    }
    private func engineStateChanged(_ st: EngineState) {
        panes.listening?.refreshLiveStatus(st)
        sidebar?.refreshStatus(st, perms: PermissionsState.current)
        // Recording badge in the content toolbar (Listening pane only).
        if case .recording = st, currentPaneId == .listening {
            toolbarBadge?.isHidden = false
            toolbarBadge?.set(kind: .danger, label: "Recording")
        } else {
            toolbarBadge?.isHidden = true
        }
    }

    // MARK: Pane selection

    private func select(_ id: PaneId, animated: Bool = true) {
        currentPaneId = id
        toolbarBadge?.isHidden = !(id == .listening && (engine?.state.isRecording ?? false))

        guard let container = contentContainer else { return }
        let new = view(for: id)
        let scroll = wrapInScroll(new)
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let old = container.subviews.first
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        if animated, let old {
            scroll.alphaValue = 0
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                old.animator().alphaValue = 0
                scroll.animator().alphaValue = 1
            }, completionHandler: {
                old.removeFromSuperview()
            })
        } else {
            old?.removeFromSuperview()
        }

        sidebar?.setSelected(id)
    }

    private func view(for id: PaneId) -> NSView {
        switch id {
        case .listening:
            if let p = panes.listening { return p }
            let p = ListeningPane(
                cfg: cfg,
                engineState: { [weak self] in self?.engine?.state ?? .paused },
                onPause: { [weak self] in self?.toggleListening() },
                changes: { [weak self] block in self?.mutateCfg(block) }
            )
            panes.listening = p
            return p
        case .notes:
            if let p = panes.notes { return p }
            let p = NotesPane(
                cfg: cfg,
                drainBacklog: { [weak self] in self?.engine?.drainBacklog() },
                changes: { [weak self] block in self?.mutateCfg(block) }
            )
            panes.notes = p
            return p
        case .transcription:
            if let p = panes.transcription { return p }
            let p = TranscriptionPane(
                cfg: cfg,
                rowAction: { [weak self] key in self?.handleModelRowAction(key) },
                openConfig: { [weak self] in self?.openJSON() },
                changes: { [weak self] block in self?.mutateCfg(block) }
            )
            panes.transcription = p
            return p
        case .summary:
            if let p = panes.summary { return p }
            let p = SummaryPane(
                cfg: cfg,
                openConfig: { [weak self] in self?.openJSON() },
                changes: { [weak self] block in self?.mutateCfg(block) }
            )
            panes.summary = p
            return p
        case .updates:
            if let p = panes.updates { return p }
            let p = UpdatesPane(
                cfg: cfg,
                onCheckNow: { [weak self] in self?.checkForUpdates() },
                changes: { [weak self] block in self?.mutateCfg(block) }
            )
            panes.updates = p
            return p
        case .advanced:
            if let p = panes.advanced { return p }
            let p = AdvancedPane(
                openConfig: { [weak self] in self?.openJSON() },
                revealData: { [weak self] in self?.revealDataFolder() },
                runDiagnose: { [weak self] in self?.runCLI("diagnose-detect") },
                runSelftest: { [weak self] in self?.runCLI("selftest") },
                runDoctor: { [weak self] in self?.runCLI("doctor") },
                resetSettings: { [weak self] in self?.resetAllSettings() }
            )
            panes.advanced = p
            return p
        case .about:
            if let p = panes.about { return p }
            let p = AboutPane(openReleases: {
                NSWorkspace.shared.open(Updater.releasesPage)
            })
            panes.about = p
            return p
        }
    }

    private func wrapInScroll(_ doc: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.contentBg
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder

        // FlippedView so content lays out from the top and the page opens at
        // the top, not the bottom (same trick the old form used).
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(doc)
        doc.translatesAutoresizingMaskIntoConstraints = false
        // 4 pt top inset so the page title sits at the same y as the
        // sidebar's brand row (which is itself 4 pt below the 38 pt drag
        // region). Anything bigger drops the header noticeably lower than
        // "Ghostie" in the sidebar.
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: flipped.topAnchor, constant: 4),
            doc.leadingAnchor.constraint(equalTo: flipped.leadingAnchor, constant: 28),
            doc.trailingAnchor.constraint(equalTo: flipped.trailingAnchor, constant: -28),
            doc.bottomAnchor.constraint(lessThanOrEqualTo: flipped.bottomAnchor, constant: -32)
        ])

        scroll.documentView = flipped
        NSLayoutConstraint.activate([
            flipped.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            flipped.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            flipped.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])
        return scroll
    }

    // MARK: Mutations + save

    /// Edits go into the in-memory config and are persisted immediately so the
    /// running engine sees them on the very next call. Save-on-close is gone —
    /// every knob is a live toggle, matching the System-Settings model.
    private func mutateCfg(_ block: (inout Config) -> Void) {
        block(&cfg)
        if cfg.save() {
            onSave(Config.load())
        }
    }

    // MARK: Actions

    private func toggleListening() {
        guard let engine else { return }
        if engine.isListening { engine.stopListening() } else { engine.startListening() }
        panes.listening?.refreshLiveStatus(engine.state)
        sidebar?.refreshStatus(engine.state, perms: PermissionsState.current)
    }

    private func openJSON() {
        let url = URL(fileURLWithPath: Config.configPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            Config.loadRaw().save()
        }
        NSWorkspace.shared.open(url)
    }

    private func revealDataFolder() {
        let p = "\(NSHomeDirectory())/.ghostie"
        try? FileManager.default.createDirectory(atPath: p, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
    }

    private func runCLI(_ subcommand: String) {
        // Find the same binary that's running us, so the CLI sees the same
        // bundle / config. Fall back to `ghostie` on PATH if we can't.
        let me = CommandLine.arguments[0]
        let bin = FileManager.default.isExecutableFile(atPath: me) ? me : "/usr/local/bin/ghostie"
        let cmd = "\(bin.shellEscaped) \(subcommand)"
        let script = "tell application \"Terminal\"\n  activate\n  do script \"\(cmd)\"\nend tell"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }

    private func resetAllSettings() {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = "Put every setting back to default?"
        a.informativeText = "Your notes, the queued calls, and the models you've downloaded stay put — only Ghostie's settings are reset."
        a.addButton(withTitle: "Reset")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        cfg = Config()
        if cfg.save() { onSave(Config.load()) }
        // Rebuild panes so the UI reflects defaults.
        panes = PaneRefs()
        select(currentPaneId, animated: false)
    }

    // MARK: Updates

    private func checkForUpdates() {
        guard let up = panes.updates else { return }
        if updater.isRunning { return }
        up.setBusy(true, statusText: "Checking…")
        updater.check(config: Config.load()) { [weak self] result in
            guard let self else { return }
            up.setBusy(false, statusText: nil)
            switch result {
            case .success(.upToDate(let cur)):
                up.show(status: .upToDate(version: "\(cur)"))
            case .success(.skippedUnsupportedBuild):
                up.show(status: .unsupported)
            case .failure(let e):
                up.show(status: .failed(e.localizedDescription))
            case .success(.available(let r, let cur)):
                up.show(status: .available(from: "\(cur)", to: r.tag, notes: r.notes))
                let a = NSAlert()
                a.messageText = "Update Ghostie to \(r.tag)?"
                a.informativeText = (r.notes.isEmpty ? "" : r.notes + "\n\n")
                    + "Ghostie will download and verify the update, then quit and relaunch. It won't interrupt an active call."
                a.addButton(withTitle: "Update Now")
                a.addButton(withTitle: "Later")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                up.setBusy(true, statusText: "Updating…")
                self.updater.downloadAndInstall(r, engine: self.engine,
                    status: { s in DispatchQueue.main.async { up.setBusy(true, statusText: s) } },
                    finish: { err in
                        DispatchQueue.main.async {
                            up.setBusy(false, statusText: nil)
                            if let err {
                                let a = NSAlert()
                                a.alertStyle = .critical
                                a.messageText = "Update failed"
                                a.informativeText = err.localizedDescription
                                a.runModal()
                            }
                        }
                    },
                    commit: { [weak self] in
                        if let engine = self?.engine {
                            engine.shutdown {
                                DispatchQueue.main.async { NSApp.terminate(nil) }
                            }
                        } else {
                            DispatchQueue.main.async { NSApp.terminate(nil) }
                        }
                    })
            }
        }
    }

    // MARK: Model row actions

    /// Resolve the row key to the Model it currently represents. The "kb"
    /// row depends on the variant in the in-memory config, so it has to
    /// recompute each time.
    fileprivate func modelForKey(_ key: String) -> Model? {
        switch key {
        case "base":     return Models.baseEnglish
        case "large-v3": return Models.largeV3
        case "vad":      return Models.sileroVAD
        case "kb":
            let v = cfg.codeSwitch.kbWhisperVariant
            return Models.kbWhisperLarge(variant: v.isEmpty ? "standard" : v)
        default: return nil
        }
    }

    private func handleModelRowAction(_ key: String) {
        guard let model = modelForKey(key) else { return }
        let h = ModelDownloader.health(for: [model])[0]
        switch h.state {
        case .missing, .sizeWrong, .hashMismatch:
            if inflightModelKey == key {
                downloader.cancel()
                inflightModelKey = nil
                panes.transcription?.refreshAllRows()
            } else {
                startDownload(model, key: key)
            }
        case .noSidecar:
            startAdopt(model, key: key)
        case .ok:
            startReverify(model, key: key)
        }
    }

    private func startDownload(_ model: Model, key: String) {
        guard inflightModelKey == nil else { return }
        inflightModelKey = key
        panes.transcription?.setRowDownloading(key, percent: 0, status: "Starting…")
        downloader.start(models: [model], status: { [weak self] s in
            let pct = Self.parsePercent(s) ?? 0
            self?.panes.transcription?.setRowDownloading(key, percent: pct, status: s)
        }, finish: { [weak self] err in
            guard let self else { return }
            self.inflightModelKey = nil
            if let err {
                let a = NSAlert()
                a.alertStyle = .critical
                a.messageText = "Download failed"
                a.informativeText = err.localizedDescription
                a.runModal()
            }
            self.panes.transcription?.refreshAllRows()
        })
    }

    private func startAdopt(_ model: Model, key: String) {
        guard inflightModelKey == nil else { return }
        panes.transcription?.setRowBusy(key, status: "Verifying (HEAD + SHA256)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = ModelDownloader.adopt(model)
            DispatchQueue.main.async { self?.panes.transcription?.refreshRow(key) }
        }
    }

    private func startReverify(_ model: Model, key: String) {
        guard inflightModelKey == nil else { return }
        panes.transcription?.setRowBusy(key, status: "Re-hashing…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = ModelDownloader.health(for: [model])
            DispatchQueue.main.async { self?.panes.transcription?.refreshRow(key) }
        }
    }

    static func parsePercent(_ s: String) -> Double? {
        // "Downloading … 62%  (X MB/Y MB)" → 0.62
        guard let pct = s.range(of: #"\b(\d{1,3})%"#, options: .regularExpression) else { return nil }
        let n = Int(s[pct].dropLast()) ?? 0
        return Double(min(max(n, 0), 100)) / 100.0
    }
}

private extension EngineState {
    var isRecording: Bool {
        if case .recording = self { return true } else { return false }
    }
}

private extension String {
    /// Quote a path for `do script` (AppleScript). Simple enough: escape any
    /// embedded backslashes / double-quotes; the destination is interpreted by
    /// /bin/sh, so spaces and parens land in the quoted form unchanged.
    var shellEscaped: String {
        let escaped = self
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\\\"\(escaped)\\\""
    }
}

// MARK: - Pane identity

private enum PaneId: String, CaseIterable {
    case listening, notes, transcription, summary, updates, advanced, about

    static let mainOrder: [PaneId] = [.listening, .notes, .transcription, .summary, .updates]
    static let bottomOrder: [PaneId] = [.advanced, .about]

    var title: String {
        switch self {
        case .listening:     return "Listening"
        case .notes:         return "Notes"
        case .transcription: return "Transcription"
        case .summary:       return "Summary"
        case .updates:       return "Updates"
        case .advanced:      return "Developer"
        case .about:         return "About"
        }
    }

    var systemSymbol: String {
        switch self {
        case .listening:     return "mic"
        case .notes:         return "folder"
        case .transcription: return "waveform"
        case .summary:       return "sparkles"
        case .updates:       return "arrow.triangle.2.circlepath"
        case .advanced:      return "hammer"
        case .about:         return "info.circle"
        }
    }
}

/// Single global "Show advanced" flag. Replaced the per-pane disclosures —
/// having one switch per pane meant the user had to flip it five times to see
/// every advanced row. One switch in the sidebar covers all panes; the panes
/// listen on `didChange` and re-show their advanced cards.
enum Disclosure {
    static let key = "ghostie.advanced"
    static let didChange = Notification.Name("ghostie.disclosure.didChange")
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
    static func toggle() { isOn.toggle() }
}

// MARK: - Theme tokens

enum Theme {

    static var windowBg: NSColor   { dyn(light: 0xECECEF, dark: 0x1C1C1E) }
    static var contentBg: NSColor  { dyn(light: 0xFFFFFF, dark: 0x1C1C1E) }
    static var cardBg: NSColor     { dyn(light: 0xFFFFFF, dark: 0x2C2C2E) }
    static var sidebarBg: NSColor  { dyn(light: 0xF6F6F9, dark: 0x242426) }
    static var cardBorder: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(white: 1, alpha: 0.07)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.14)
        }
    }
    static var rowDivider: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(white: 1, alpha: 0.07)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.12)
        }
    }
    static var chipBg: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(white: 1, alpha: 0.06)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.08)
        }
    }
    static var selectedItem: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(white: 1, alpha: 0.10)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.12)
        }
    }
    static var text: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(white: 1, alpha: 0.92)
                : NSColor(white: 0, alpha: 0.86)
        }
    }
    static var text2: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(red: 235/255, green: 235/255, blue: 245/255, alpha: 0.60)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.62)
        }
    }
    static var text3: NSColor {
        NSColor(name: nil) { ap in
            isDark(ap)
                ? NSColor(red: 235/255, green: 235/255, blue: 245/255, alpha: 0.35)
                : NSColor(red: 60/255, green: 60/255, blue: 67/255, alpha: 0.35)
        }
    }
    static var accent: NSColor     { dyn(light: 0x5E5CE6, dark: 0x7D7AFF) }
    static var ok: NSColor         { dyn(light: 0x1F9D55, dark: 0x30D158) }
    static var warn: NSColor       { dyn(light: 0xB46300, dark: 0xFF9F0A) }
    static var danger: NSColor     { dyn(light: 0xC93B32, dark: 0xFF453A) }
    static var info: NSColor       { dyn(light: 0x0067CC, dark: 0x0A84FF) }

    static var okSoft: NSColor     { soft(.ok) }
    static var warnSoft: NSColor   { soft(.warn) }
    static var dangerSoft: NSColor { soft(.danger) }
    static var infoSoft: NSColor   { soft(.info) }
    static var accentSoft: NSColor { soft(.accent) }

    static var toolbarBg: NSColor      { sidebarBg }
    static var toolbarBorder: NSColor  { cardBorder }
    static var inputBorder: NSColor    { cardBorder }

    private static func dyn(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { ap in
            isDark(ap) ? rgb(dark) : rgb(light)
        }
    }
    /// True when `ap` is any dark appearance. A plain `ap.name == .darkAqua`
    /// check misses the *vibrant* variants (`.vibrantDark`) that AppKit hands
    /// to views inside an `NSVisualEffectView` — e.g. the whole settings
    /// sidebar, which is a vibrant `NSSplitViewItem` sidebar. `bestMatch`
    /// collapses every dark/vibrant-dark variant onto `.darkAqua`.
    private static func isDark(_ ap: NSAppearance) -> Bool {
        ap.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(red: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    private enum SoftKind { case ok, warn, danger, info, accent }
    private static func soft(_ k: SoftKind) -> NSColor {
        NSColor(name: nil) { ap in
            let base: NSColor
            switch k {
            case .ok:     base = isDark(ap) ? rgb(0x30D158) : rgb(0x1F9D55)
            case .warn:   base = isDark(ap) ? rgb(0xFF9F0A) : rgb(0xB46300)
            case .danger: base = isDark(ap) ? rgb(0xFF453A) : rgb(0xC93B32)
            case .info:   base = isDark(ap) ? rgb(0x0A84FF) : rgb(0x0067CC)
            case .accent: base = isDark(ap) ? rgb(0x7D7AFF) : rgb(0x5E5CE6)
            }
            return base.withAlphaComponent(isDark(ap) ? 0.18 : 0.13)
        }
    }
}

// MARK: - Primitives

extension NSView {
    /// Resolve a (possibly dynamic light/dark) `NSColor` to a `CGColor` in
    /// *this view's* current effective appearance.
    ///
    /// Plain `NSColor.cgColor` snapshots whatever the ambient drawing
    /// appearance happens to be at the moment of the call. That ambient value
    /// is correct at launch but is **not** refreshed for you inside
    /// `viewDidChangeEffectiveAppearance` — so a layer background assigned via
    /// `Theme.x.cgColor` freezes at whatever mode the window first opened in
    /// and never follows a system dark/light switch. Dynamic colors used
    /// *directly* (text colors, image tints, `NSScrollView.backgroundColor`)
    /// are fine because AppKit re-resolves those itself; only the `cgColor`
    /// snapshots on `CALayer`s need this. Resolving inside the view's own
    /// `effectiveAppearance` makes the snapshot track the switch.
    func themedCG(_ color: NSColor) -> CGColor {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }
}

/// A layer-backed `NSView` whose layer colors are re-resolved on every
/// light/dark switch. A naked `NSView()` can't react to appearance changes;
/// this one re-runs `themeApply` — both when first assigned and on every
/// `viewDidChangeEffectiveAppearance` — with the view's current appearance
/// installed as the drawing appearance, so plain `.cgColor` inside it resolves
/// correctly.
private final class ThemedLayerView: NSView {
    var themeApply: ((ThemedLayerView) -> Void)? { didSet { refreshTheme() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTheme()
    }
    private func refreshTheme() {
        guard let themeApply else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance { themeApply(self) }
    }
}

private final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = themedCG(Theme.contentBg)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = themedCG(Theme.contentBg)
    }
}

/// The little ghost in the sidebar brand row. Solid black silhouette from
/// `GhostIcon.bodyPath`, two white pupils that follow the mouse pointer
/// anywhere in the Settings window via a local event monitor.
private final class GhostBrandView: NSView {

    private var lookOffset = NSPoint.zero
    private var monitor: Any?
    /// Pupil offset is clamped to a small radius so the eye stays cleanly
    /// inside the ghost's face even when the cursor is in the far corner.
    private static let maxOffset: CGFloat = 1.8

    override init(frame: NSRect) {
        super.init(frame: frame)
        // No layer-backed background — the previous indigo tile is gone, so
        // the ghost draws straight onto the sidebar's vibrancy.
        // Watch every mouse-moved event in the app while this view is alive.
        // `addLocalMonitorForEvents` runs the callback before the event hits
        // the responder chain, which means we don't need a tracking area on
        // the whole window. Re-render on every move.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] event in
            self?.updateGaze(toWindowPoint: event.locationInWindow)
            return event
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    private func updateGaze(toWindowPoint p: NSPoint) {
        guard window != nil else { return }
        let pInView = convert(p, from: nil)
        let center = NSPoint(x: bounds.midX, y: bounds.midY + bounds.height * 0.10)
        let dx = pInView.x - center.x
        let dy = pInView.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 0 else { lookOffset = .zero; needsDisplay = true; return }
        // Normalize direction and pin to max offset — the eyes always commit
        // to looking at the cursor, near or far.
        let scale = Self.maxOffset / dist
        lookOffset = NSPoint(x: dx * scale, y: dy * scale)
        needsDisplay = true
    }

    override func draw(_ rect: NSRect) {
        // Black ghost body, no backdrop. The full view is the ghost.
        let face = bounds
        let body = GhostIcon.bodyPath(in: face)
        NSColor.labelColor.setFill()   // black in light mode, white in dark
        body.fill()

        // Sclera (the white of the eye) sits at a fixed position on the
        // ghost's face. The iris is a smaller, darker oval inside the sclera
        // that translates with `lookOffset` so the gaze follows the cursor.
        let (sL, _, sR, _) = GhostIcon.eyeRects(in: face)
        let scleraW = face.width * 0.22
        let scleraH = face.width * 0.28
        let irisW = face.width * 0.11
        let irisH = face.width * 0.14

        NSColor.white.setFill()
        let leftSclera = NSRect(x: sL.midX - scleraW / 2,
                                 y: sL.midY - scleraH / 2,
                                 width: scleraW, height: scleraH)
        let rightSclera = NSRect(x: sR.midX - scleraW / 2,
                                  y: sR.midY - scleraH / 2,
                                  width: scleraW, height: scleraH)
        NSBezierPath(ovalIn: leftSclera).fill()
        NSBezierPath(ovalIn: rightSclera).fill()

        // Black iris on the white sclera — monochrome by design. Stays
        // black in both light and dark mode (the sclera is always white,
        // so a black iris reads correctly either way).
        NSColor.black.setFill()
        let leftIris = NSRect(x: sL.midX - irisW / 2 + lookOffset.x,
                              y: sL.midY - irisH / 2 + lookOffset.y,
                              width: irisW, height: irisH)
        let rightIris = NSRect(x: sR.midX - irisW / 2 + lookOffset.x,
                               y: sR.midY - irisH / 2 + lookOffset.y,
                               width: irisW, height: irisH)
        NSBezierPath(ovalIn: leftIris).fill()
        NSBezierPath(ovalIn: rightIris).fill()
    }
}

/// Card with a 0.5 pt border and 10 pt corner radius. Holds rows + dividers.
private final class GroupCard: NSView {
    private let stack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    init(title: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if let title {
            titleLabel.stringValue = title.uppercased()
            titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            titleLabel.textColor = Theme.text2
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true
        stack.layer?.backgroundColor = themedCG(Theme.cardBg)
        stack.layer?.cornerRadius = 10
        stack.layer?.borderWidth = 0.5
        stack.layer?.borderColor = themedCG(Theme.cardBorder)
        stack.layer?.masksToBounds = true
        stack.edgeInsets = .init()

        addSubview(stack)
        var consts: [NSLayoutConstraint] = []
        if title != nil {
            addSubview(titleLabel)
            consts += [
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                titleLabel.topAnchor.constraint(equalTo: topAnchor),
                stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7)
            ]
        } else {
            consts += [stack.topAnchor.constraint(equalTo: topAnchor)]
        }
        consts += [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(consts)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stack.layer?.backgroundColor = themedCG(Theme.cardBg)
        stack.layer?.borderColor = themedCG(Theme.cardBorder)
    }

    func addRow(_ row: NSView, last: Bool = false) {
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        if !last {
            let div = DividerView()
            stack.addArrangedSubview(div)
            div.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
            div.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            div.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        }
    }
}

private final class DividerView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = themedCG(Theme.rowDivider)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = themedCG(Theme.rowDivider)
    }
}

private final class PageHeaderView: NSView {
    init(title: String, subtitle: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 22, weight: .bold)
        t.textColor = Theme.text
        t.translatesAutoresizingMaskIntoConstraints = false
        addSubview(t)
        var consts: [NSLayoutConstraint] = [
            t.topAnchor.constraint(equalTo: topAnchor),
            t.leadingAnchor.constraint(equalTo: leadingAnchor),
            t.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ]
        if let subtitle {
            let s = NSTextField(wrappingLabelWithString: subtitle)
            s.font = .systemFont(ofSize: 12.5)
            s.textColor = Theme.text2
            s.translatesAutoresizingMaskIntoConstraints = false
            s.preferredMaxLayoutWidth = 560
            addSubview(s)
            consts += [
                s.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 3),
                s.leadingAnchor.constraint(equalTo: leadingAnchor),
                s.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                s.bottomAnchor.constraint(equalTo: bottomAnchor)
            ]
        } else {
            consts += [t.bottomAnchor.constraint(equalTo: bottomAnchor)]
        }
        NSLayoutConstraint.activate(consts)
    }
    required init?(coder: NSCoder) { fatalError() }
}

private final class StatusBadgeView: NSView {

    enum Kind { case ok, warn, danger, info, muted, accent }

    private var kind: Kind
    private var label: String
    private let dot = NSView()
    private let text = NSTextField(labelWithString: "")
    private var pulseLayer: CAShapeLayer?

    init(kind: Kind, label: String, pulsing: Bool = false) {
        self.kind = kind
        self.label = label
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        text.font = .systemFont(ofSize: 11, weight: .semibold)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(text)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18)
        ])
        apply()
        if pulsing { startPulse() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(kind: Kind, label: String) {
        self.kind = kind
        self.label = label
        apply()
    }

    private var cachedLabel: String?
    private var cachedKind: Kind?

    private func apply() {
        let (bg, fg) = colors(for: kind)
        layer?.backgroundColor = themedCG(bg)
        dot.layer?.backgroundColor = themedCG(fg)
        dot.layer?.cornerRadius = 3
        // NSTextField redraws on every stringValue/textColor assignment even
        // when the value hasn't changed, which cascades back into our redraw
        // chain — only push when something is actually new.
        if cachedLabel != label {
            cachedLabel = label
            text.stringValue = label
        }
        if cachedKind != kind {
            cachedKind = kind
            text.textColor = fg
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let (bg, fg) = colors(for: kind)
        layer?.backgroundColor = themedCG(bg)
        dot.layer?.backgroundColor = themedCG(fg)
        text.textColor = fg
    }

    func startPulse() {
        guard pulseLayer == nil else { return }
        let r = CAShapeLayer()
        r.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 6, height: 6), transform: nil)
        let (_, fg) = colors(for: kind)
        r.fillColor = fg.withAlphaComponent(0.5).cgColor
        r.frame = CGRect(x: 0, y: 0, width: 6, height: 6)
        dot.layer?.addSublayer(r)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 2.8
        scale.duration = 1.6
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let op = CABasicAnimation(keyPath: "opacity")
        op.fromValue = 0.5
        op.toValue = 0.0
        op.duration = 1.6
        op.repeatCount = .infinity
        r.add(scale, forKey: "scale")
        r.add(op, forKey: "opacity")
        pulseLayer = r
    }

    func stopPulse() {
        pulseLayer?.removeAllAnimations()
        pulseLayer?.removeFromSuperlayer()
        pulseLayer = nil
    }

    private func colors(for k: Kind) -> (bg: NSColor, fg: NSColor) {
        switch k {
        case .ok:     return (Theme.okSoft, Theme.ok)
        case .warn:   return (Theme.warnSoft, Theme.warn)
        case .danger: return (Theme.dangerSoft, Theme.danger)
        case .info:   return (Theme.infoSoft, Theme.info)
        case .accent: return (Theme.accentSoft, Theme.accent)
        case .muted:  return (Theme.chipBg, Theme.text2)
        }
    }
}

/// One settings row. Optional leading tinted icon tile, label + sub, trailing
/// control. The control area is a single NSView so callers can drop any control
/// (toggle, segmented control, button, badge) into the same slot.
private final class RowBuilder {
    static func row(label: String,
                    sub: String? = nil,
                    leadingSymbol: String? = nil,
                    leadingImage: NSImage? = nil,
                    leadingImageBare: Bool = false,
                    leadingTint: NSColor? = nil,
                    control: NSView? = nil,
                    danger: Bool = false) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        var leading: NSView = row
        var leadingConstant: CGFloat = 14
        // Either an SF Symbol name or a pre-made template image gets the same
        // leading-tile treatment. `leadingImage` wins if both are supplied.
        let symbolImage = leadingSymbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        if let image = leadingImage ?? symbolImage {
            let tile = ThemedLayerView()
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.image = image
            iv.contentTintColor = leadingTint != nil ? .white : .secondaryLabelColor
            tile.addSubview(iv)
            row.addSubview(tile)

            if leadingImageBare {
                // No tile background, no chrome. The image fills the leading
                // area at its native aspect ratio (height pinned, width
                // proportionally scaled by NSImageView).
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.imageAlignment = .alignCenter
                NSLayoutConstraint.activate([
                    tile.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                    tile.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    tile.widthAnchor.constraint(equalToConstant: 26),
                    tile.heightAnchor.constraint(equalToConstant: 26),
                    iv.topAnchor.constraint(equalTo: tile.topAnchor),
                    iv.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
                    iv.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
                    iv.trailingAnchor.constraint(equalTo: tile.trailingAnchor)
                ])
            } else {
                tile.themeApply = { $0.layer?.backgroundColor = (leadingTint ?? Theme.chipBg).cgColor }
                tile.layer?.cornerRadius = 6
                NSLayoutConstraint.activate([
                    tile.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                    tile.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    tile.widthAnchor.constraint(equalToConstant: 26),
                    tile.heightAnchor.constraint(equalToConstant: 26),
                    iv.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                    iv.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 15),
                    iv.heightAnchor.constraint(equalToConstant: 15)
                ])
            }
            leading = tile
            leadingConstant = 12
        }

        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = danger ? Theme.danger : Theme.text
        l.translatesAutoresizingMaskIntoConstraints = false
        l.lineBreakMode = .byTruncatingTail
        row.addSubview(l)

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 1.5
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(labelStack)
        labelStack.addArrangedSubview(l)
        if let sub {
            let s = NSTextField(wrappingLabelWithString: sub)
            s.font = .systemFont(ofSize: 11.5)
            s.textColor = Theme.text2
            // `wrappingLabelWithString` defaults to `.byWordWrapping`. Leave
            // it alone — overriding to `.byTruncatingTail` was killing the
            // wrap and letting the text run behind the trailing control.
            s.translatesAutoresizingMaskIntoConstraints = false
            s.maximumNumberOfLines = 2
            // Allow the layout solver to shrink the sub freely so it wraps
            // when a wide control (e.g. an NSPopUpButton) occupies the right
            // side of the row.
            s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            s.setContentHuggingPriority(.defaultLow, for: .horizontal)
            labelStack.addArrangedSubview(s)
            s.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        }
        l.removeFromSuperview()
        labelStack.insertArrangedSubview(l, at: 0)

        var constraints: [NSLayoutConstraint] = []
        if leading !== row {
            // A leading tile (icon) was added — anchor the label stack to it.
            constraints += [
                labelStack.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: leadingConstant)
            ]
        } else {
            constraints += [
                labelStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14)
            ]
        }
        constraints += [
            labelStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 11),
            labelStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -11),
        ]

        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                control.leadingAnchor.constraint(greaterThanOrEqualTo: labelStack.trailingAnchor, constant: 12)
            ]
        } else {
            constraints += [labelStack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -14)]
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    static func numberInput(value: String, suffix: String?, width: CGFloat = 64,
                            target: AnyObject?, action: Selector?) -> NSView {
        let tf = NSTextField()
        tf.stringValue = value
        tf.alignment = .right
        tf.font = .systemFont(ofSize: 12.5)
        tf.bezelStyle = .roundedBezel
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.target = target
        tf.action = action
        tf.widthAnchor.constraint(equalToConstant: width).isActive = true
        if let suffix {
            let s = NSTextField(labelWithString: suffix)
            s.font = .systemFont(ofSize: 12)
            s.textColor = Theme.text2
            let h = NSStackView(views: [tf, s])
            h.orientation = .horizontal
            h.spacing = 6
            h.alignment = .firstBaseline
            h.translatesAutoresizingMaskIntoConstraints = false
            return h
        }
        return tf
    }

    static func button(_ title: String,
                       kind: ButtonKind = .secondary,
                       target: AnyObject?, action: Selector?) -> NSButton {
        let b = StyledButton(title: title, target: target, action: action)
        b.kind = kind
        return b
    }
}

enum ButtonKind { case primary, secondary, danger, ghost }

/// A flat NSButton that uses a layer-backed background so it can match the
/// design tokens regardless of the running macOS theme. Stays an `NSButton`
/// underneath so target/action wiring and keyboard handling are unchanged.
private final class StyledButton: NSButton {

    var kind: ButtonKind = .secondary { didSet { restyle() } }

    override var title: String {
        // Once attributedTitle is set, NSButton stops honouring `title` for
        // display — so a `button.title = "Resume"` swap from outside would
        // otherwise leave the old attributed string on screen. Hook the setter
        // and rebuild the attributed title whenever the underlying title moves.
        didSet { restyle() }
    }

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.translatesAutoresizingMaskIntoConstraints = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 6
        self.layer?.borderWidth = 0.5
        self.font = .systemFont(ofSize: 12, weight: .medium)
        self.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 22, height: max(s.height, 24))
    }

    private var cachedTitle: String = ""
    private var cachedFg: NSColor?

    /// Recompute the layer colours + attributed title. Idempotent: skips the
    /// attributed-title rebuild when the title and resolved foreground haven't
    /// changed, otherwise this would recurse forever — setting `attributedTitle`
    /// inside `updateLayer()` marks the button for redisplay, which re-fires
    /// `updateLayer()`, allocating a new NSAttributedString each loop until the
    /// process eats all available memory. Layer colors go through `themedCG`
    /// so they re-resolve correctly when called from
    /// `viewDidChangeEffectiveAppearance` on a light/dark switch.
    private func restyle() {
        let (bg, fg, border) = colors()
        layer?.backgroundColor = themedCG(bg)
        layer?.borderColor = themedCG(border)
        if cachedTitle != title || cachedFg != fg {
            cachedTitle = title
            cachedFg = fg
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: fg,
                    .font: font ?? .systemFont(ofSize: 12, weight: .medium)
                ])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func colors() -> (NSColor, NSColor, NSColor) {
        switch kind {
        case .primary:   return (Theme.accent, .white, .clear)
        case .secondary: return (Theme.chipBg, Theme.text, .clear)
        case .ghost:     return (.clear, Theme.text, Theme.inputBorder)
        case .danger:    return (.clear, Theme.danger, Theme.danger)
        }
    }
}

// MARK: - Permissions state

private struct PermissionsState {
    let mic: Bool
    let micDenied: Bool
    let screen: Bool
    let ax: Bool

    var allRequiredGranted: Bool { mic && screen }
    var allGranted: Bool { mic && screen && ax }
    var bundleIdMismatch: Bool {
        // CLI builds carry a different code identity than the installed .app;
        // a grant against the CLI doesn't transfer. Surface it as if the
        // perms were missing so the banner explains the situation.
        !CommandLine.arguments[0].contains(".app/Contents/MacOS/")
    }

    static var current: PermissionsState {
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        return PermissionsState(
            mic: micAuth == .authorized,
            micDenied: micAuth == .denied,
            screen: CGPreflightScreenCaptureAccess(),
            ax: AXIsProcessTrusted())
    }
}

// MARK: - Sidebar

private final class Sidebar: NSView {

    private let paneOrder: [PaneId]
    private let paneBottom: [PaneId]
    private let onSelect: (PaneId) -> Void

    private var itemRows: [PaneId: SidebarItem] = [:]
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    /// Last status-dot color, kept so a light/dark switch can re-resolve the
    /// `cgColor` snapshot without waiting for the next engine state change.
    private var statusDotColor: NSColor = Theme.text3
    private weak var engine: Engine?

    init(paneOrder: [PaneId], paneBottom: [PaneId], initialPane: PaneId,
         engine: Engine?, onSelect: @escaping (PaneId) -> Void) {
        self.paneOrder = paneOrder
        self.paneBottom = paneBottom
        self.engine = engine
        self.onSelect = onSelect
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = themedCG(Theme.sidebarBg)
        build(selecting: initialPane)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = themedCG(Theme.sidebarBg)
        statusDot.layer?.backgroundColor = themedCG(statusDotColor)
    }

    private func build(selecting initial: PaneId) {
        // Top drag region — height of the traffic-light area.
        let dragRegion = NSView()
        dragRegion.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragRegion)

        // Brand row — the little ghost in the sidebar, with eyes that
        // follow the mouse around the Settings window.
        let brand = NSView()
        brand.translatesAutoresizingMaskIntoConstraints = false
        let logo = GhostBrandView()
        logo.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Ghostie")
        title.font = .systemFont(ofSize: 13.5, weight: .bold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [title])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        let statusLine = NSStackView(views: [statusDot, statusLabel])
        statusLine.orientation = .horizontal
        statusLine.alignment = .centerY
        statusLine.spacing = 4
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        titleStack.addArrangedSubview(statusLine)

        brand.addSubview(logo)
        brand.addSubview(titleStack)
        addSubview(brand)

        NSLayoutConstraint.activate([
            dragRegion.topAnchor.constraint(equalTo: topAnchor),
            dragRegion.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragRegion.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragRegion.heightAnchor.constraint(equalToConstant: 38),

            brand.topAnchor.constraint(equalTo: dragRegion.bottomAnchor, constant: 4),
            brand.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            brand.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            logo.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
            logo.topAnchor.constraint(equalTo: brand.topAnchor),
            logo.widthAnchor.constraint(equalToConstant: 38),
            logo.heightAnchor.constraint(equalToConstant: 38),

            titleStack.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            titleStack.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            titleStack.trailingAnchor.constraint(equalTo: brand.trailingAnchor),

            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),

            brand.bottomAnchor.constraint(equalTo: logo.bottomAnchor)
        ])

        // Nav list.
        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 1
        nav.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nav)
        for id in paneOrder {
            let item = SidebarItem(id: id, onClick: { [weak self] in self?.onSelect($0) })
            nav.addArrangedSubview(item)
            item.leadingAnchor.constraint(equalTo: nav.leadingAnchor).isActive = true
            item.trailingAnchor.constraint(equalTo: nav.trailingAnchor).isActive = true
            itemRows[id] = item
        }
        let powerUser = NSTextField(labelWithString: "POWER USER")
        powerUser.font = .systemFont(ofSize: 10, weight: .semibold)
        powerUser.textColor = .tertiaryLabelColor
        let powerWrap = NSView()
        powerWrap.translatesAutoresizingMaskIntoConstraints = false
        powerWrap.addSubview(powerUser)
        powerUser.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            powerUser.leadingAnchor.constraint(equalTo: powerWrap.leadingAnchor, constant: 4),
            powerUser.topAnchor.constraint(equalTo: powerWrap.topAnchor, constant: 18),
            powerUser.bottomAnchor.constraint(equalTo: powerWrap.bottomAnchor, constant: -4),
            powerUser.trailingAnchor.constraint(lessThanOrEqualTo: powerWrap.trailingAnchor)
        ])
        nav.addArrangedSubview(powerWrap)
        powerWrap.leadingAnchor.constraint(equalTo: nav.leadingAnchor).isActive = true
        powerWrap.trailingAnchor.constraint(equalTo: nav.trailingAnchor).isActive = true
        for id in paneBottom {
            let item = SidebarItem(id: id, onClick: { [weak self] in self?.onSelect($0) })
            nav.addArrangedSubview(item)
            item.leadingAnchor.constraint(equalTo: nav.leadingAnchor).isActive = true
            item.trailingAnchor.constraint(equalTo: nav.trailingAnchor).isActive = true
            itemRows[id] = item
        }

        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 14),
            nav.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nav.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])

        // Global Advanced toggle — bottom-left. One switch covers every pane;
        // each pane listens on `Disclosure.didChange` and re-renders its
        // advanced section. Tap target spans label + switch so a click on
        // either flips state.
        let advLabel = NSTextField(labelWithString: "Advanced")
        advLabel.font = .systemFont(ofSize: 12, weight: .medium)
        advLabel.textColor = .secondaryLabelColor
        advLabel.translatesAutoresizingMaskIntoConstraints = false

        let advSwitch = NSSwitch()
        advSwitch.controlSize = .mini
        advSwitch.state = Disclosure.isOn ? .on : .off
        advSwitch.translatesAutoresizingMaskIntoConstraints = false
        let advTarget = ToggleTarget { Disclosure.isOn = (advSwitch.state == .on) }
        advSwitch.target = advTarget
        advSwitch.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(advSwitch, &ToggleTarget.key, advTarget, .OBJC_ASSOCIATION_RETAIN)

        let advRow = NSView()
        advRow.translatesAutoresizingMaskIntoConstraints = false
        advRow.addSubview(advLabel)
        advRow.addSubview(advSwitch)
        // Clicking the label flips the switch — easier target than the
        // (mini) switch knob alone. Held strongly via objc_setAssociatedObject
        // since `NSGestureRecognizer.target` is weak.
        let labelTarget = ActionTarget {
            Disclosure.toggle()
            advSwitch.state = Disclosure.isOn ? .on : .off
        }
        let labelClick = NSClickGestureRecognizer(
            target: labelTarget, action: #selector(ActionTarget.fire))
        advLabel.addGestureRecognizer(labelClick)
        objc_setAssociatedObject(advLabel, &ActionTarget.key, labelTarget,
                                 .OBJC_ASSOCIATION_RETAIN)
        addSubview(advRow)

        NSLayoutConstraint.activate([
            advRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            advRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            advRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            advRow.heightAnchor.constraint(equalToConstant: 22),
            advLabel.leadingAnchor.constraint(equalTo: advRow.leadingAnchor),
            advLabel.centerYAnchor.constraint(equalTo: advRow.centerYAnchor),
            advSwitch.trailingAnchor.constraint(equalTo: advRow.trailingAnchor),
            advSwitch.centerYAnchor.constraint(equalTo: advRow.centerYAnchor)
        ])

        widthAnchor.constraint(equalToConstant: 220).isActive = true
        setSelected(initial)
        refreshStatus(engine?.state ?? .paused, perms: PermissionsState.current)
    }

    func setSelected(_ id: PaneId) {
        for (k, v) in itemRows { v.setActive(k == id) }
    }

    func refreshStatus(_ state: EngineState, perms: PermissionsState) {
        switch state {
        case .paused:
            statusDotColor = Theme.text3
            statusLabel.stringValue = "Paused"
        case .watching:
            statusDotColor = Theme.ok
            statusLabel.stringValue = "Watching"
        case .recording(let since):
            statusDotColor = Theme.danger
            let secs = Int(Date().timeIntervalSince(since))
            statusLabel.stringValue = String(format: "Recording · %02d:%02d", secs / 60, secs % 60)
        case .processing:
            statusDotColor = Theme.info
            statusLabel.stringValue = "Summarizing"
        }
        statusDot.layer?.backgroundColor = themedCG(statusDotColor)
        itemRows[.listening]?.setBadge(perms.allRequiredGranted ? nil : .warn)
    }
}

private final class SidebarItem: NSView {
    private let id: PaneId
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var badge = NSView()
    private let onClick: (PaneId) -> Void
    private var active = false
    private var trackingArea: NSTrackingArea?

    init(id: PaneId, onClick: @escaping (PaneId) -> Void) {
        self.id = id
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: id.systemSymbol,
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        // System semantic colors instead of Theme.text2/Theme.text. The custom
        // dynamic NSColor providers (NSColor(name: nil) { ap in ... }) were
        // freezing at light-mode resolution inside layer-backed sidebar items
        // and never refreshing — `.secondaryLabelColor` / `.labelColor` are
        // managed by AppKit and update reliably on appearance changes.
        icon.contentTintColor = .secondaryLabelColor

        label.stringValue = id.title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        badge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        addSubview(badge)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ on: Bool) {
        active = on
        applyTheme()
    }

    /// Re-resolve every dynamic color we depend on. Layer-backed views capture
    /// `cgColor` snapshots that don't track appearance changes, and AppKit
    /// occasionally caches `NSTextField`/`NSImageView` tints set before the
    /// window's effective appearance flipped to `.darkAqua`. Calling this on
    /// both `setActive(_:)` and `viewDidChangeEffectiveAppearance` keeps the
    /// sidebar legible whether the user toggles dark mode at launch or
    /// mid-session.
    private func applyTheme() {
        layer?.backgroundColor = active ? themedCG(Theme.selectedItem) : NSColor.clear.cgColor
        icon.contentTintColor = active ? Theme.accent : .secondaryLabelColor
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: 13, weight: active ? .semibold : .medium)
        label.needsDisplay = true
        icon.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    enum BadgeKind { case warn }
    func setBadge(_ kind: BadgeKind?) {
        badge.subviews.forEach { $0.removeFromSuperview() }
        guard let kind else { return }
        let dot = ThemedLayerView()
        dot.themeApply = { $0.layer?.backgroundColor = (kind == .warn ? Theme.warn : Theme.danger).cgColor }
        dot.layer?.cornerRadius = 4
        badge.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 12),
            badge.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        if !active { layer?.backgroundColor = themedCG(Theme.chipBg) }
    }
    override func mouseExited(with event: NSEvent) {
        if !active { layer?.backgroundColor = NSColor.clear.cgColor }
    }
    override func mouseDown(with event: NSEvent) {
        onClick(id)
    }
}

// MARK: - Pane: Listening

private final class ListeningPane: NSView {

    private let cfg: Config
    private let engineState: () -> EngineState
    private let onPause: () -> Void
    private let changes: ((inout Config) -> Void) -> Void

    private var permsCard: NSView?
    private var liveStatusRow: LiveStatusRow!
    private var permsContainer = NSStackView()
    private var advancedContainer = NSStackView()
    private var paneStack = NSStackView()
    private var timer: Timer?
    private var disclosureToken: NSObjectProtocol?

    init(cfg: Config,
         engineState: @escaping () -> EngineState,
         onPause: @escaping () -> Void,
         changes: @escaping ((inout Config) -> Void) -> Void) {
        self.cfg = cfg
        self.engineState = engineState
        self.onPause = onPause
        self.changes = changes
        super.init(frame: .zero)
        build()
        disclosureToken = NotificationCenter.default.addObserver(
            forName: Disclosure.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAdvanced()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        timer?.invalidate()
        if let disclosureToken { NotificationCenter.default.removeObserver(disclosureToken) }
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        paneStack.orientation = .vertical
        paneStack.alignment = .leading
        paneStack.spacing = 22
        paneStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paneStack)
        NSLayoutConstraint.activate([
            paneStack.topAnchor.constraint(equalTo: topAnchor),
            paneStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let header = PageHeaderView(title: "Listening",
                                    subtitle: "When Ghostie watches for Teams calls and how it confirms one is real.")
        paneStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true

        permsContainer.orientation = .vertical
        permsContainer.alignment = .leading
        permsContainer.spacing = 22
        permsContainer.translatesAutoresizingMaskIntoConstraints = false
        paneStack.addArrangedSubview(permsContainer)
        permsContainer.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true
        rebuildPermissions()

        // Live status card.
        liveStatusRow = LiveStatusRow(onPause: { [weak self] in self?.onPause() })
        let liveCard = GroupCard()
        liveCard.addRow(liveStatusRow, last: true)
        paneStack.addArrangedSubview(liveCard)
        liveCard.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true
        refreshLiveStatus(engineState())

        // Detection group. (Used to expose a "Require Microsoft Teams" toggle
        // here — removed because the new detector always requires a match
        // against `triggerBundleIds` and ignored the legacy flag.)
        let detection = GroupCard(title: "Detection")
        detection.addRow(buildStepperRow(
            label: "End-call grace",
            sub: "How long Teams must stay quiet before Ghostie decides the call has ended.",
            initial: Int(cfg.endGraceSeconds),
            range: 5...600,
            suffix: "s") { [weak self] v in
                self?.changes { c in c.endGraceSeconds = Double(v) }
            })
        detection.addRow(buildStepperRow(
            label: "Ignore short calls",
            sub: "Anything shorter than this gets thrown away without writing a note.",
            initial: Int(cfg.minCallSeconds),
            range: 0...600,
            suffix: "s") { [weak self] v in
                self?.changes { c in c.minCallSeconds = Double(v) }
            }, last: true)
        paneStack.addArrangedSubview(detection)
        detection.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true

        // Advanced container — driven by the global Disclosure toggle in the
        // sidebar; no per-pane disclosure footer.
        advancedContainer.orientation = .vertical
        advancedContainer.alignment = .leading
        advancedContainer.spacing = 22
        advancedContainer.translatesAutoresizingMaskIntoConstraints = false
        paneStack.addArrangedSubview(advancedContainer)
        advancedContainer.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true
        refreshAdvanced()

        // Per-second tick to keep the elapsed time accurate while recording.
        // `.common` mode so the tile keeps updating when the window isn't
        // key (e.g. the user clicks into another app with Settings still
        // visible). `Timer.scheduledTimer` would install on `.default` only.
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshLiveStatus(self.engineState())
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func refreshPermissions() {
        rebuildPermissions()
    }

    private func rebuildPermissions() {
        permsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let p = PermissionsState.current
        if p.bundleIdMismatch {
            let card = WarningCard(title: "These permissions won't stick",
                                   body: "You launched Ghostie from the command line, not from /Applications/Ghostie.app. macOS keeps permissions per app, so anything you grant here won't apply to the installed app. Quit, then open Ghostie from /Applications.")
            permsContainer.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: permsContainer.widthAnchor).isActive = true
        } else if !p.allRequiredGranted {
            let banner = PermissionsBanner(state: p)
            permsContainer.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: permsContainer.widthAnchor).isActive = true
        } else {
            let card = GroupCard(title: "System Access")
            card.addRow(RowBuilder.row(
                label: "Microphone",
                sub: "Lets Ghostie capture your voice during a Teams call.",
                leadingSymbol: "mic.fill", leadingTint: Theme.danger,
                control: StatusBadgeView(kind: .ok, label: "Granted")))
            card.addRow(RowBuilder.row(
                label: "Screen Recording",
                sub: "Used to capture the other participants — Ghostie only keeps the audio, never the picture.",
                leadingSymbol: "display", leadingTint: Theme.info,
                control: StatusBadgeView(kind: .ok, label: "Granted")))
            card.addRow(RowBuilder.row(
                label: "Accessibility",
                sub: p.ax
                    ? "Helps Ghostie tell a real Teams meeting apart from the app just being open. Optional."
                    : "Optional — helps Ghostie spot a real meeting window. Calls still get recorded without it.",
                leadingSymbol: "figure.stand", leadingTint: NSColor.systemGray,
                control: StatusBadgeView(kind: p.ax ? .ok : .muted,
                                         label: p.ax ? "Granted" : "Skipped")),
                        last: true)
            permsContainer.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: permsContainer.widthAnchor).isActive = true
        }
    }

    func refreshLiveStatus(_ state: EngineState) {
        liveStatusRow?.apply(state: state)
    }

    private func refreshAdvanced() {
        advancedContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard Disclosure.isOn else { return }
        let card = GroupCard(title: "Detection · Advanced")
        // Parens matter — `??` binds looser than `+`, so the previous form
        // (`first ?? "..." + suffix`) silently dropped the "+N" tail and only
        // showed the fallback string with the count when `first` was nil.
        let primary = cfg.triggerBundleIds.first ?? "com.microsoft.teams"
        let extras = cfg.triggerBundleIds.count > 1
            ? " +\(cfg.triggerBundleIds.count - 1)"
            : ""
        card.addRow(RowBuilder.row(
            label: "Apps that count as Teams",
            sub: "Ghostie only treats microphone activity as a call when one of these apps is running.",
            control: NSTextField(labelWithString: primary + extras)
                .styledAsMono()), last: true)
        advancedContainer.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: advancedContainer.widthAnchor).isActive = true
    }

    private func buildToggleRow(label: String, sub: String, on: Bool,
                                onChange: @escaping (Bool) -> Void) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = on ? .on : .off
        toggle.translatesAutoresizingMaskIntoConstraints = false
        let target = ToggleTarget { onChange(toggle.state == .on) }
        toggle.target = target
        toggle.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(toggle, &ToggleTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return RowBuilder.row(label: label, sub: sub, control: toggle)
    }

    private func buildStepperRow(label: String, sub: String, initial: Int,
                                 range: ClosedRange<Int>, suffix: String,
                                 onChange: @escaping (Int) -> Void,
                                 last: Bool = false) -> NSView {
        let tf = NSTextField()
        tf.stringValue = String(initial)
        tf.alignment = .right
        tf.font = .systemFont(ofSize: 12.5)
        tf.bezelStyle = .roundedBezel
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.integerValue = initial
        stepper.translatesAutoresizingMaskIntoConstraints = false
        let suffixL = NSTextField(labelWithString: suffix)
        suffixL.font = .systemFont(ofSize: 12)
        suffixL.textColor = Theme.text2
        let target = StepperTarget(tf: tf, stepper: stepper) { v in onChange(v) }
        stepper.target = target
        stepper.action = #selector(StepperTarget.stepperChanged)
        tf.target = target
        tf.action = #selector(StepperTarget.textChanged)
        tf.delegate = target
        objc_setAssociatedObject(stepper, &StepperTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        let h = NSStackView(views: [tf, stepper, suffixL])
        h.orientation = .horizontal
        h.spacing = 6
        h.alignment = .firstBaseline
        return RowBuilder.row(label: label, sub: sub, control: h)
    }
}

private final class ToggleTarget {
    static var key: UInt8 = 0
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

private final class StepperTarget: NSObject, NSTextFieldDelegate {
    static var key: UInt8 = 0
    let tf: NSTextField
    let stepper: NSStepper
    let onChange: (Int) -> Void
    init(tf: NSTextField, stepper: NSStepper, onChange: @escaping (Int) -> Void) {
        self.tf = tf; self.stepper = stepper; self.onChange = onChange
    }
    @objc func stepperChanged() {
        tf.integerValue = stepper.integerValue
        onChange(stepper.integerValue)
    }
    @objc func textChanged() {
        if let v = Int(tf.stringValue) {
            let clamped = max(Int(stepper.minValue), min(Int(stepper.maxValue), v))
            stepper.integerValue = clamped
            tf.integerValue = clamped
            onChange(clamped)
        }
    }
    func controlTextDidEndEditing(_ obj: Notification) { textChanged() }
}

// MARK: - Live status row

private final class LiveStatusRow: NSView {
    private let tile = NSView()
    private let symbol = NSImageView()
    private var pulseLayer: CAShapeLayer?
    /// Last tile color, kept so a light/dark switch can re-resolve the
    /// `cgColor` snapshot — the tile color otherwise only refreshes on the
    /// next engine state change.
    private var tileBg: NSColor = Theme.chipBg
    private func setTileBg(_ c: NSColor) {
        tileBg = c
        tile.layer?.backgroundColor = themedCG(c)
    }
    private let title = NSTextField(labelWithString: "")
    private let timeMono = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let button: StyledButton
    private let onPause: () -> Void

    init(onPause: @escaping () -> Void) {
        self.onPause = onPause
        self.button = StyledButton(title: "Pause listening", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 10
        symbol.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbol)
        addSubview(tile)

        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = Theme.text
        title.translatesAutoresizingMaskIntoConstraints = false

        timeMono.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        timeMono.textColor = Theme.text2
        timeMono.translatesAutoresizingMaskIntoConstraints = false

        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Theme.text2
        detail.translatesAutoresizingMaskIntoConstraints = false

        let titleLine = NSStackView(views: [title, timeMono])
        titleLine.orientation = .horizontal
        titleLine.alignment = .firstBaseline
        titleLine.spacing = 10

        let stack = NSStackView(views: [titleLine, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let pauseTarget = ActionTarget { [weak self] in self?.onPause() }
        button.target = pauseTarget
        button.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(button, &ActionTarget.key, pauseTarget, .OBJC_ASSOCIATION_RETAIN)
        addSubview(button)

        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 42),
            tile.heightAnchor.constraint(equalToConstant: 42),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 20),
            symbol.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(equalTo: tile.topAnchor, constant: -14),
            bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: 14)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(state: EngineState) {
        if case .recording = state { startPulse() } else { stopPulse() }
        switch state {
        case .recording(let since):
            setTileBg(Theme.dangerSoft)
            symbol.image = NSImage(systemSymbolName: "record.circle",
                                   accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            symbol.contentTintColor = Theme.danger
            title.stringValue = "Recording"
            let secs = Int(Date().timeIntervalSince(since))
            timeMono.stringValue = String(format: "%02d:%02d", secs / 60, secs % 60)
            timeMono.isHidden = false
            detail.stringValue = "A Teams call is in progress."
            button.title = "Pause listening"
            button.kind = .ghost
        case .watching:
            setTileBg(Theme.okSoft)
            symbol.image = NSImage(systemSymbolName: "mic",
                                   accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            symbol.contentTintColor = Theme.ok
            title.stringValue = "Watching for calls"
            timeMono.stringValue = ""
            timeMono.isHidden = true
            detail.stringValue = "Idle. Ghostie will wake up the next time Teams starts using the mic."
            button.title = "Pause listening"
            button.kind = .ghost
        case .processing:
            setTileBg(Theme.infoSoft)
            symbol.image = NSImage(systemSymbolName: "sparkles",
                                   accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            symbol.contentTintColor = Theme.info
            title.stringValue = "Writing the note"
            timeMono.stringValue = ""
            timeMono.isHidden = true
            detail.stringValue = "Claude is reading the transcript and pulling out the highlights."
            button.title = "Pause listening"
            button.kind = .ghost
        case .paused:
            setTileBg(Theme.chipBg)
            symbol.image = NSImage(systemSymbolName: "pause.fill",
                                   accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            symbol.contentTintColor = Theme.text2
            title.stringValue = "Paused"
            timeMono.stringValue = ""
            timeMono.isHidden = true
            detail.stringValue = "Ghostie isn't watching for calls right now."
            button.title = "Resume listening"
            button.kind = .primary
        }
    }

    /// Single ring under the symbol that scales out and fades — the recording
    /// pulse from the design spec. Removed on every non-recording state.
    private func startPulse() {
        guard pulseLayer == nil, tile.layer != nil else { return }
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 12, height: 12), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = Theme.danger.cgColor
        ring.lineWidth = 1.5
        ring.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        ring.position = CGPoint(x: 21, y: 21)
        tile.layer?.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 2.8
        scale.duration = 1.6
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let op = CABasicAnimation(keyPath: "opacity")
        op.fromValue = 0.5
        op.toValue = 0.0
        op.duration = 1.6
        op.repeatCount = .infinity
        ring.add(scale, forKey: "scale")
        ring.add(op, forKey: "opacity")
        pulseLayer = ring
    }
    private func stopPulse() {
        pulseLayer?.removeAllAnimations()
        pulseLayer?.removeFromSuperlayer()
        pulseLayer = nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tile.layer?.backgroundColor = themedCG(tileBg)
    }
}

private final class ActionTarget {
    static var key: UInt8 = 0
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

// MARK: - Permissions banner

private final class PermissionsBanner: NSView {
    /// Re-resolves every layer `cgColor` in the banner — its own border/fill
    /// plus the warning badge and the inner card — on a light/dark switch.
    private var themeRefresh: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { themeRefresh?() }
    }

    init(state: PermissionsState) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.borderColor = themedCG(Theme.warn)
        layer?.backgroundColor = themedCG(Theme.warnSoft)
        layer?.masksToBounds = true

        // Header.
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let badge = NSView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 13
        badge.layer?.backgroundColor = themedCG(Theme.warn)
        let bang = NSImageView()
        bang.translatesAutoresizingMaskIntoConstraints = false
        bang.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        bang.contentTintColor = .white
        badge.addSubview(bang)
        let title = NSTextField(labelWithString:
            state.mic ? "One more permission needed"
                      : "Ghostie can't record calls yet")
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.textColor = Theme.text
        let sub = NSTextField(wrappingLabelWithString:
            "macOS needs your okay before Ghostie can listen to a call.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = Theme.text2
        let textStack = NSStackView(views: [title, sub])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(badge); header.addSubview(textStack)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            badge.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            bang.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            bang.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            textStack.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            header.bottomAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 10)
        ])
        addSubview(header)

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.wantsLayer = true
        inner.layer?.backgroundColor = themedCG(Theme.cardBg)
        addSubview(inner)

        themeRefresh = { [weak self, weak badge, weak inner] in
            self?.layer?.borderColor = Theme.warn.cgColor
            self?.layer?.backgroundColor = Theme.warnSoft.cgColor
            badge?.layer?.backgroundColor = Theme.warn.cgColor
            inner?.layer?.backgroundColor = Theme.cardBg.cgColor
        }

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            inner.topAnchor.constraint(equalTo: header.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        var first = true
        if !state.mic {
            inner.addArrangedSubview(permRow(
                first: first, name: "Microphone",
                why: state.micDenied
                    ? "Currently blocked. Turn this on in System Settings so Ghostie can capture your voice."
                    : "Lets Ghostie capture your voice during a call.",
                symbol: "mic",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
            first = false
        }
        if !state.screen {
            inner.addArrangedSubview(permRow(
                first: first, name: "Screen Recording",
                why: "Lets Ghostie capture the other participants. Only the audio is kept, never the picture.",
                symbol: "display",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))
            first = false
        }
        if !state.ax {
            inner.addArrangedSubview(permRow(
                first: first, name: "Accessibility", optional: true,
                why: "Helps Ghostie tell a real Teams meeting apart from the app just being open.",
                symbol: "figure.stand",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))
            first = false
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func permRow(first: Bool, name: String, optional: Bool = false,
                         why: String, symbol: String, url: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let divider = DividerView()
        divider.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        icon.contentTintColor = Theme.text2

        let title = NSMutableAttributedString(
            string: name, attributes: [
                .foregroundColor: Theme.text,
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)
            ])
        if optional {
            title.append(NSAttributedString(
                string: "  ·  optional", attributes: [
                    .foregroundColor: Theme.text3,
                    .font: NSFont.systemFont(ofSize: 11)
                ]))
        }
        let titleL = NSTextField(labelWithAttributedString: title)
        titleL.translatesAutoresizingMaskIntoConstraints = false
        let whyL = NSTextField(wrappingLabelWithString: why)
        whyL.font = .systemFont(ofSize: 11)
        whyL.textColor = Theme.text2
        whyL.translatesAutoresizingMaskIntoConstraints = false
        whyL.preferredMaxLayoutWidth = 380
        let textStack = NSStackView(views: [titleL, whyL])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let target = OpenURLTarget(url: url)
        let btn = StyledButton(title: "Open in System Settings",
                               target: target, action: #selector(OpenURLTarget.fire))
        btn.kind = .primary
        objc_setAssociatedObject(btn, &OpenURLTarget.key, target, .OBJC_ASSOCIATION_RETAIN)

        row.addSubview(icon)
        row.addSubview(textStack)
        row.addSubview(btn)
        if !first { row.addSubview(divider) }
        var consts: [NSLayoutConstraint] = [
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9),
            btn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            btn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            btn.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 12)
        ]
        if !first {
            consts += [
                divider.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                divider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                divider.topAnchor.constraint(equalTo: row.topAnchor),
                divider.heightAnchor.constraint(equalToConstant: 0.5)
            ]
        }
        NSLayoutConstraint.activate(consts)
        return row
    }
}

private final class OpenURLTarget {
    static var key: UInt8 = 0
    let url: String
    init(url: String) { self.url = url }
    @objc func fire() {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}

private final class WarningCard: NSView {
    init(title: String, body: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.borderColor = themedCG(Theme.warn)
        layer?.backgroundColor = themedCG(Theme.warnSoft)
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.textColor = Theme.text
        let b = NSTextField(wrappingLabelWithString: body)
        b.font = .systemFont(ofSize: 12)
        b.textColor = Theme.text2
        b.preferredMaxLayoutWidth = 600
        let stack = NSStackView(views: [t, b])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = themedCG(Theme.warn)
        layer?.backgroundColor = themedCG(Theme.warnSoft)
    }
}

// MARK: - Pane: Notes

private final class NotesPane: NSView {
    private let cfg: Config
    private let changes: ((inout Config) -> Void) -> Void
    private let drainBacklog: () -> Void
    private let pathLabel = NSTextField(labelWithString: "")
    private var notesFolder: String
    private let advContainer = NSStackView()
    private var disclosureToken: NSObjectProtocol?

    init(cfg: Config,
         drainBacklog: @escaping () -> Void,
         changes: @escaping ((inout Config) -> Void) -> Void) {
        self.cfg = cfg
        self.drainBacklog = drainBacklog
        self.changes = changes
        self.notesFolder = cfg.notesFolder
        super.init(frame: .zero)
        build()
        disclosureToken = NotificationCenter.default.addObserver(
            forName: Disclosure.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAdvanced()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let disclosureToken { NotificationCenter.default.removeObserver(disclosureToken) }
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let header = PageHeaderView(title: "Notes",
                                    subtitle: "Where Ghostie writes the summary after a call and what else it keeps on disk.")
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Notes folder + actions.
        let card = GroupCard()
        let folderTarget = ActionTarget { [weak self] in self?.chooseFolder() }
        let chooseBtn = StyledButton(title: "Choose…", target: folderTarget,
                                     action: #selector(ActionTarget.fire))
        chooseBtn.kind = .secondary
        objc_setAssociatedObject(chooseBtn, &ActionTarget.key, folderTarget, .OBJC_ASSOCIATION_RETAIN)
        let revealTarget = ActionTarget { [weak self] in
            guard let self else { return }
            let url = URL(fileURLWithPath: self.notesFolder)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
        let revealBtn = StyledButton(title: "Reveal", target: revealTarget,
                                     action: #selector(ActionTarget.fire))
        revealBtn.kind = .secondary
        objc_setAssociatedObject(revealBtn, &ActionTarget.key, revealTarget, .OBJC_ASSOCIATION_RETAIN)
        let h = NSStackView(views: [chooseBtn, revealBtn])
        h.orientation = .horizontal
        h.spacing = 6

        pathLabel.stringValue = cfg.notesFolder.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        card.addRow(RowBuilder.row(
            label: "Notes folder",
            sub: pathLabel.stringValue,
            leadingSymbol: "folder.fill", leadingTint: Theme.accent,
            control: h))

        card.addRow(buildToggleRow(
            label: "Save the full transcript too",
            sub: "Write the raw transcript next to each summary, in case you need the verbatim version.",
            on: cfg.saveTranscript) { [weak self] on in
                self?.changes { c in c.saveTranscript = on }
            })

        card.addRow(buildToggleRow(
            label: "Keep the recording",
            sub: "Off by default — Ghostie throws the audio away once the note has been written.",
            on: cfg.keepAudio) { [weak self] on in
                self?.changes { c in c.keepAudio = on }
            }, last: true)

        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        advContainer.orientation = .vertical
        advContainer.alignment = .leading
        advContainer.spacing = 22
        advContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(advContainer)
        advContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        refreshAdvanced()
    }

    private func refreshAdvanced() {
        advContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard Disclosure.isOn else { return }
        let card = GroupCard(title: "Backlog")
        let pending = Backlog.pendingCount
        let pendingControl: NSView
        if pending > 0 {
            let drainTarget = ActionTarget { [weak self] in self?.drainBacklog() }
            let drainBtn = StyledButton(title: "Process now", target: drainTarget,
                                        action: #selector(ActionTarget.fire))
            drainBtn.kind = .primary
            objc_setAssociatedObject(drainBtn, &ActionTarget.key, drainTarget, .OBJC_ASSOCIATION_RETAIN)
            let badge = StatusBadgeView(kind: .warn, label: "\(pending) queued")
            let h = NSStackView(views: [badge, drainBtn])
            h.orientation = .horizontal
            h.spacing = 8
            h.alignment = .centerY
            pendingControl = h
        } else {
            pendingControl = StatusBadgeView(kind: .muted, label: "0 queued")
        }
        card.addRow(RowBuilder.row(
            label: "Waiting in the queue",
            sub: "Calls that couldn't be processed yet — usually because transcription or Claude wasn't reachable at the time.",
            control: pendingControl))
        card.addRow(RowBuilder.row(
            label: "Retry every",
            sub: "How often Ghostie tries the queue again on its own.",
            control: NSTextField(labelWithString: "10 min").styledAsMono()),
                    last: true)
        advContainer.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: advContainer.widthAnchor).isActive = true
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        if !notesFolder.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: notesFolder).deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            notesFolder = url.path
            pathLabel.stringValue = url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            changes { c in c.notesFolder = url.path }
        }
    }

    private func buildToggleRow(label: String, sub: String, on: Bool,
                                onChange: @escaping (Bool) -> Void,
                                last: Bool = false) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = on ? .on : .off
        let target = ToggleTarget { onChange(toggle.state == .on) }
        toggle.target = target
        toggle.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(toggle, &ToggleTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return RowBuilder.row(label: label, sub: sub, control: toggle)
    }
}

// MARK: - Pane: Transcription

private final class TranscriptionPane: NSView {

    private struct ModelRowState {
        let row: ModelRowView
        let key: String
    }

    private var cfg: Config
    private let rowAction: (String) -> Void
    private let openConfig: () -> Void
    private let parentChanges: ((inout Config) -> Void) -> Void
    private let advContainer = NSStackView()
    private var rows: [String: ModelRowState] = [:]
    private var disclosureToken: NSObjectProtocol?

    init(cfg: Config,
         rowAction: @escaping (String) -> Void,
         openConfig: @escaping () -> Void,
         changes: @escaping ((inout Config) -> Void) -> Void) {
        self.cfg = cfg
        self.rowAction = rowAction
        self.openConfig = openConfig
        self.parentChanges = changes
        super.init(frame: .zero)
        build()
        disclosureToken = NotificationCenter.default.addObserver(
            forName: Disclosure.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAdvanced()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let disclosureToken { NotificationCenter.default.removeObserver(disclosureToken) }
    }

    /// Apply a config mutation locally and to the persisted config in one
    /// step. The pane caches `cfg` so the model-row refresh and radio
    /// selection read coherent state without going back to disk.
    private func change(_ block: (inout Config) -> Void) {
        block(&cfg)
        parentChanges(block)
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let header = PageHeaderView(title: "Transcription",
                                    subtitle: "How Ghostie turns the recording into text and which models it runs locally on your Mac.")
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Mode — dropdown over single vs. dual-language transcription. Writes
        // to `codeSwitch.languages` (the v2 intent signal — empty/1 = single,
        // 2+ = code-switching); the Models card reacts to the selection
        // (KB + large-v3 paired vs. base/large-v3 alone). The pipeline only
        // *actually* code-switches when ≥2 models are installed on disk.
        let mode = GroupCard(title: "Mode")
        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modePopup.addItems(withTitles: [
            "Single language",
            "Language switching (Swedish ↔ English)"
        ])
        modePopup.selectItem(at: cfg.codeSwitch.languages.count >= 2 ? 1 : 0)
        modePopup.translatesAutoresizingMaskIntoConstraints = false
        modePopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        let modeTarget = ToggleTarget { [weak self] in
            let on = modePopup.indexOfSelectedItem == 1
            self?.change { c in
                c.codeSwitch.languages = on ? ["sv", "en"] : ["en"]
            }
            self?.refreshAllRows()
        }
        modePopup.target = modeTarget
        modePopup.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(modePopup, &ToggleTarget.key, modeTarget, .OBJC_ASSOCIATION_RETAIN)
        mode.addRow(RowBuilder.row(
            label: "Transcription mode",
            sub: "Pick language switching for calls that mix Swedish and English.",
            control: modePopup), last: true)
        stack.addArrangedSubview(mode)
        mode.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Models.
        let modelsCard = GroupCard(title: "Models")
        let modelDefs: [(key: String, title: String, subtitle: String, size: String)] = [
            ("base",     "Whisper base",        "English only. ~150 MB. The quick one.",   "150 MB"),
            ("large-v3", "Whisper large-v3",    "Speaks every language. ~1.1 GB. The accurate one.", "1.1 GB"),
            ("kb",       "KB-Whisper-large (sv)","Swedish specialist. ~1.1 GB. Runs alongside Whisper large for mixed-language calls.", "1.1 GB"),
            ("vad",      "Silero VAD",          "~900 KB. Lets Ghostie skip silent stretches so it doesn't invent words.", "900 KB")
        ]
        for (i, m) in modelDefs.enumerated() {
            let row = ModelRowView(key: m.key, title: m.title, subtitle: m.subtitle)
            row.onAction = { [weak self] in self?.rowAction(m.key) }
            modelsCard.addRow(row, last: i == modelDefs.count - 1)
            rows[m.key] = ModelRowState(row: row, key: m.key)
        }
        stack.addArrangedSubview(modelsCard)
        modelsCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Quality.
        let quality = GroupCard(title: "Quality")
        quality.addRow(buildToggleRow(
            label: "Tidy up the transcript",
            sub: "Trims the things Whisper sometimes invents in silent stretches, like \"Thanks for watching.\"",
            on: cfg.cleanTranscript) { [weak self] on in
                self?.change { c in c.cleanTranscript = on }
            })
        let vadOnDisk = FileManager.default.fileExists(atPath: Models.sileroVAD.destPath)
        quality.addRow(RowBuilder.row(
            label: "Skip the quiet bits",
            sub: vadOnDisk ? "Ghostie uses the Silero model below to find pauses and ignore them."
                           : "Download the Silero VAD model below to turn this on.",
            control: StatusBadgeView(kind: vadOnDisk ? .ok : .muted,
                                     label: vadOnDisk ? "Active" : "Inactive")),
                       last: true)
        stack.addArrangedSubview(quality)
        quality.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        advContainer.orientation = .vertical
        advContainer.alignment = .leading
        advContainer.spacing = 22
        advContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(advContainer)
        advContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        refreshAdvanced()

        refreshAllRows()
    }

    private func refreshAdvanced() {
        advContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard Disclosure.isOn else { return }
        let card = GroupCard(title: "Transcription · Advanced")
        let editTarget = ActionTarget { [weak self] in self?.openConfig() }
        let editBtn = StyledButton(title: "Edit in config.json",
                                   target: editTarget, action: #selector(ActionTarget.fire))
        objc_setAssociatedObject(editBtn, &ActionTarget.key, editTarget, .OBJC_ASSOCIATION_RETAIN)
        card.addRow(RowBuilder.row(
            label: "Starter sentence",
            sub: cfg.initialPrompt.isEmpty
                ? "Empty — Ghostie will let Whisper figure punctuation out on its own."
                : cfg.initialPrompt,
            control: editBtn))
        let editTarget2 = ActionTarget { [weak self] in self?.openConfig() }
        let editBtn2 = StyledButton(title: "Edit in config.json",
                                    target: editTarget2, action: #selector(ActionTarget.fire))
        objc_setAssociatedObject(editBtn2, &ActionTarget.key, editTarget2, .OBJC_ASSOCIATION_RETAIN)
        card.addRow(RowBuilder.row(
            label: "Decoding knobs",
            sub: "How carefully Whisper second-guesses itself. Tuned for clean business speech.",
            control: editBtn2))
        card.addRow(RowBuilder.row(
            label: "Cross-language confidence",
            sub: "How much weight Ghostie gives the other speaker when picking a language. 0.5 means no help, 1.0 means override.",
            control: NSTextField(labelWithString:
                String(format: "%.2f", cfg.codeSwitch.crossTrackPriorStrength))
                .styledAsMono()), last: true)
        advContainer.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: advContainer.widthAnchor).isActive = true
    }

    func refreshRow(_ key: String) {
        guard let st = rows[key], let model = modelForKey(key) else { return }
        let h = ModelDownloader.health(for: [model])[0]
        let single = cfg.codeSwitch.languages.count < 2
        // Single-mode pairs with one whisper model (base or large-v3); the KB
        // row pairs with large-v3 in codeswitch mode and only then.
        let selected: Bool = {
            switch key {
            case "base":
                return single && cfg.whisperModel == Models.baseEnglish.destPath
            case "large-v3":
                return (single && cfg.whisperModel == Models.largeV3.destPath)
                    || (!single)
            case "kb":
                return !single
            case "vad":
                // VAD has no explicit toggle in Config — whisper-cli uses it
                // automatically whenever the file is on disk. Show a tick to
                // confirm it's active rather than leaving the row indicator
                // permanently blank.
                return h.state.isOK
            default:
                return false
            }
        }()
        st.row.apply(state: h.state, selected: selected, isPaired: key == "kb" && !single)
    }

    func refreshAllRows() {
        for key in rows.keys { refreshRow(key) }
    }

    func setRowDownloading(_ key: String, percent: Double, status: String) {
        rows[key]?.row.setDownloading(percent: percent, status: status)
    }
    func setRowBusy(_ key: String, status: String) {
        rows[key]?.row.setBusy(status: status)
    }

    private func modelForKey(_ key: String) -> Model? {
        switch key {
        case "base":     return Models.baseEnglish
        case "large-v3": return Models.largeV3
        case "vad":      return Models.sileroVAD
        case "kb":       return Models.kbWhisperLarge(variant: cfg.codeSwitch.kbWhisperVariant.isEmpty
                                                              ? "standard"
                                                              : cfg.codeSwitch.kbWhisperVariant)
        default: return nil
        }
    }

    private func buildToggleRow(label: String, sub: String, on: Bool,
                                onChange: @escaping (Bool) -> Void) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = on ? .on : .off
        let target = ToggleTarget { onChange(toggle.state == .on) }
        toggle.target = target
        toggle.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(toggle, &ToggleTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return RowBuilder.row(label: label, sub: sub, control: toggle)
    }
}

// MARK: - Model row

private final class ModelRowView: NSView {
    private let radio = RadioCircle()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let badge = StatusBadgeView(kind: .muted, label: "Not downloaded")
    private let action: StyledButton
    private let progressBar = ProgressBar()
    private let statusLine = NSTextField(labelWithString: "")
    private var progressHeight: NSLayoutConstraint!
    private var statusHeight: NSLayoutConstraint!
    private var subtitleToBottom: NSLayoutConstraint!
    private var statusToBottom: NSLayoutConstraint!
    var onAction: (() -> Void)?

    init(key: String, title: String, subtitle: String) {
        self.action = StyledButton(title: "Download", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        self.title.stringValue = title
        self.title.font = .systemFont(ofSize: 13, weight: .semibold)
        self.title.textColor = Theme.text
        self.title.translatesAutoresizingMaskIntoConstraints = false
        self.title.setContentHuggingPriority(.required, for: .horizontal)

        self.subtitle.stringValue = subtitle
        self.subtitle.font = .systemFont(ofSize: 11.5)
        self.subtitle.textColor = Theme.text2
        self.subtitle.translatesAutoresizingMaskIntoConstraints = false

        statusLine.font = .systemFont(ofSize: 11)
        statusLine.textColor = Theme.text2
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        statusLine.isHidden = true

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true

        // Pin the action button to a fixed width so the badge column to its
        // left lands at a consistent X across all four rows. Long-enough to
        // fit the widest label ("Re-download") without truncating.
        action.widthAnchor.constraint(equalToConstant: 110).isActive = true
        badge.translatesAutoresizingMaskIntoConstraints = false

        // The title sits alone now (badge moved out to a right-aligned
        // column). `.required` hugging keeps it at its intrinsic width so
        // a shorter model name doesn't stretch into the badge column.
        let titleLine = self.title
        titleLine.translatesAutoresizingMaskIntoConstraints = false

        radio.translatesAutoresizingMaskIntoConstraints = false

        let actionTarget = ActionTarget { [weak self] in self?.onAction?() }
        action.target = actionTarget
        action.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(action, &ActionTarget.key, actionTarget, .OBJC_ASSOCIATION_RETAIN)

        addSubview(radio)
        addSubview(titleLine)
        addSubview(self.subtitle)
        addSubview(badge)
        addSubview(action)
        addSubview(progressBar)
        addSubview(statusLine)

        // Progress and status carry their own height constraints, toggled to
        // 0 when hidden so the row collapses to title + subtitle without
        // leaving phantom space.
        progressHeight = progressBar.heightAnchor.constraint(equalToConstant: 0)
        statusHeight = statusLine.heightAnchor.constraint(equalToConstant: 0)
        progressHeight.isActive = true
        statusHeight.isActive = true

        subtitleToBottom = bottomAnchor.constraint(equalTo: self.subtitle.bottomAnchor, constant: 11)
        statusToBottom = bottomAnchor.constraint(equalTo: statusLine.bottomAnchor, constant: 9)
        subtitleToBottom.isActive = true

        NSLayoutConstraint.activate([
            radio.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            radio.centerYAnchor.constraint(equalTo: titleLine.centerYAnchor),
            radio.widthAnchor.constraint(equalToConstant: 16),
            radio.heightAnchor.constraint(equalToConstant: 16),

            titleLine.leadingAnchor.constraint(equalTo: radio.trailingAnchor, constant: 12),
            titleLine.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            titleLine.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),

            self.subtitle.leadingAnchor.constraint(equalTo: titleLine.leadingAnchor),
            self.subtitle.topAnchor.constraint(equalTo: titleLine.bottomAnchor, constant: 2),
            self.subtitle.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),

            // Right-aligned badge column. Trailing pinned to a fixed offset
            // from the action button's leading edge, vertically aligned with
            // the title — matches the "Granted" column pattern in the
            // permissions card so all four pills line up on the right.
            badge.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -12),
            badge.centerYAnchor.constraint(equalTo: titleLine.centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: titleLine.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progressBar.topAnchor.constraint(equalTo: self.subtitle.bottomAnchor, constant: 8),

            statusLine.leadingAnchor.constraint(equalTo: titleLine.leadingAnchor),
            statusLine.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 3),
            statusLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),

            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            action.centerYAnchor.constraint(equalTo: titleLine.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setProgressVisible(_ visible: Bool) {
        progressBar.isHidden = !visible
        statusLine.isHidden = !visible
        progressHeight.constant = visible ? 4 : 0
        statusHeight.constant = visible ? 14 : 0
        subtitleToBottom.isActive = !visible
        statusToBottom.isActive = visible
    }

    func apply(state: ModelDownloader.HealthState, selected: Bool, isPaired: Bool) {
        setProgressVisible(false)
        radio.isSelected = selected
        radio.isPaired = isPaired
        switch state {
        case .ok:
            badge.set(kind: .ok, label: "On disk")
            action.title = "Re-verify"
            action.kind = .secondary
        case .missing:
            badge.set(kind: .muted, label: "Not downloaded")
            action.title = "Download"
            action.kind = .primary
        case .noSidecar:
            badge.set(kind: .warn, label: "Unverified")
            action.title = "Verify"
            action.kind = .secondary
        case .sizeWrong, .hashMismatch:
            badge.set(kind: .danger, label: "Mismatch")
            action.title = "Re-download"
            action.kind = .primary
        }
    }
    func setDownloading(percent: Double, status: String) {
        badge.set(kind: .info, label: "Downloading")
        action.title = "Cancel"
        action.kind = .secondary
        setProgressVisible(true)
        progressBar.set(progress: percent)
        statusLine.stringValue = status
    }
    func setBusy(status: String) {
        // Verify / re-hash: status line only, no progress bar — but we still
        // need somewhere to land the message. Reuse the progress slot with a
        // zero bar.
        setProgressVisible(true)
        progressBar.set(progress: 0)
        statusLine.stringValue = status
        action.title = "Working…"
        action.kind = .secondary
    }
}

/// Status mark in front of each model row. The model the engine actually uses
/// is driven by `cfg.codeSwitch.languages` + `cfg.whisperModel`, not by clicking
/// the row — so render a tickmark for the active model and leave the slot
/// empty otherwise. (Was previously a radio circle which implied a per-row
/// selection affordance that isn't actually wired.)
private final class RadioCircle: NSView {
    var isSelected = false { didSet { needsDisplay = true } }
    var isPaired = false { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard isSelected || isPaired else { return }
        let r = bounds.insetBy(dx: 1, dy: 1)
        Theme.accent.setStroke()
        let check = NSBezierPath()
        check.lineWidth = 1.8
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        // Three-point checkmark inscribed in the 14x14 box.
        check.move(to: CGPoint(x: r.minX + r.width * 0.18,
                               y: r.minY + r.height * 0.55))
        check.line(to: CGPoint(x: r.minX + r.width * 0.42,
                               y: r.minY + r.height * 0.78))
        check.line(to: CGPoint(x: r.minX + r.width * 0.85,
                               y: r.minY + r.height * 0.28))
        check.stroke()
    }
}

private final class ProgressBar: NSView {
    private var progress: CGFloat = 0
    private let fillLayer = CALayer()
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.backgroundColor = themedCG(Theme.chipBg)
        layer?.masksToBounds = true
        fillLayer.backgroundColor = themedCG(Theme.accent)
        fillLayer.cornerRadius = 2
        layer?.addSublayer(fillLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        // Drive the fill from layout (not updateLayer); previously this ran
        // inside updateLayer + re-added a sublayer on every pass, which
        // accumulated layers and reentered display.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(x: 0, y: 0,
                                  width: bounds.width * progress,
                                  height: bounds.height)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = themedCG(Theme.chipBg)
        fillLayer.backgroundColor = themedCG(Theme.accent)
    }
    func set(progress: Double) {
        let p = CGFloat(max(0, min(1, progress)))
        guard p != self.progress else { return }
        self.progress = p
        needsLayout = true
    }
}

// MARK: - Pane: Summary

private final class SummaryPane: NSView {
    private var cfgState: Config
    private let openConfig: () -> Void
    private let changes: ((inout Config) -> Void) -> Void
    private let providerCard = NSStackView()
    private let advContainer = NSStackView()
    private var disclosureToken: NSObjectProtocol?

    init(cfg: Config,
         openConfig: @escaping () -> Void,
         changes: @escaping ((inout Config) -> Void) -> Void) {
        self.cfgState = cfg
        self.openConfig = openConfig
        self.changes = changes
        super.init(frame: .zero)
        build()
        disclosureToken = NotificationCenter.default.addObserver(
            forName: Disclosure.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAdvanced()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit {
        if let disclosureToken { NotificationCenter.default.removeObserver(disclosureToken) }
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let header = PageHeaderView(
            title: "Summary",
            subtitle: "Choose who writes the meeting note: Claude (best quality, cloud) or a local Ollama model (fully on-device)."
        )
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Provider chooser card sits above the provider-specific configuration.
        let chooser = GroupCard()
        let seg = NSSegmentedControl(labels: ["Claude Code (cloud)", "Ollama (local)"],
                                     trackingMode: .selectOne,
                                     target: nil, action: nil)
        seg.selectedSegment = (cfgState.summaryProvider == "ollama") ? 1 : 0
        let segTarget = ToggleTarget { [weak self] in
            let next = (seg.selectedSegment == 1) ? "ollama" : "claude"
            guard let self, self.cfgState.summaryProvider != next else { return }
            self.cfgState.summaryProvider = next
            self.changes { c in c.summaryProvider = next }
            self.refreshProviderCard()
        }
        seg.target = segTarget
        seg.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(seg, &ToggleTarget.key, segTarget, .OBJC_ASSOCIATION_RETAIN)
        chooser.addRow(RowBuilder.row(
            label: "Summary provider",
            sub: "Claude is the best summarizer but the transcript leaves your Mac. Ollama runs locally — nothing leaves your machine.",
            control: seg), last: true)
        stack.addArrangedSubview(chooser)
        chooser.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Provider-specific rows go here and get rebuilt when the segment flips.
        providerCard.orientation = .vertical
        providerCard.alignment = .leading
        providerCard.spacing = 22
        providerCard.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(providerCard)
        providerCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        refreshProviderCard()

        advContainer.orientation = .vertical
        advContainer.alignment = .leading
        advContainer.spacing = 22
        advContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(advContainer)
        advContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        refreshAdvanced()
    }

    private func refreshProviderCard() {
        providerCard.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let card = buildProviderCard()
        providerCard.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: providerCard.widthAnchor).isActive = true
    }

    private func buildProviderCard() -> GroupCard {
        let card = GroupCard()
        switch cfgState.summaryProvider {
        case "ollama":
            buildOllamaRows(into: card)
        default:
            buildClaudeRows(into: card)
        }
        return card
    }

    // MARK: Claude rows (unchanged behavior, lifted into its own method)

    private func buildClaudeRows(into card: GroupCard) {
        let claudePath = cfgState.claudeBinary.isEmpty ? Config.findClaudeBinary() : cfgState.claudeBinary
        let claudeReady = !claudePath.isEmpty
        card.addRow(RowBuilder.row(
            label: "Claude Code",
            sub: claudeReady
                ? "Ready at \(claudePath.replacingOccurrences(of: NSHomeDirectory(), with: "~"))"
                : "Couldn't find Claude on this Mac. Open a terminal and run `claude` once to sign in.",
            leadingSymbol: "terminal", leadingTint: Theme.text2,
            control: StatusBadgeView(kind: claudeReady ? .ok : .warn,
                                     label: claudeReady ? "Signed in" : "Missing")))
        let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modelPopup.addItems(withTitles: ["claude-sonnet-4-6", "claude-opus-4-7", "claude-haiku-4-5-20251001"])
        modelPopup.selectItem(withTitle: cfgState.summaryModel)
        let modelTarget = ToggleTarget { [weak self] in
            let title = modelPopup.titleOfSelectedItem ?? "claude-sonnet-4-6"
            self?.cfgState.summaryModel = title
            self?.changes { c in c.summaryModel = title }
        }
        modelPopup.target = modelTarget
        modelPopup.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(modelPopup, &ToggleTarget.key, modelTarget, .OBJC_ASSOCIATION_RETAIN)
        modelPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        card.addRow(RowBuilder.row(
            label: "Which Claude writes the note",
            sub: "Sonnet is the good balance. Opus is slower but smarter. Haiku is faster but lighter.",
            control: modelPopup), last: true)
    }

    // MARK: Ollama rows

    private func buildOllamaRows(into card: GroupCard) {
        // Probe the configured server up front. This is a 2-second timeout
        // (see OllamaSummarizationProvider.probeTimeout) and runs on the main
        // thread; the rest of the UI continues to feel snappy because the
        // pane is built lazily on tab selection. Empty list ⇒ "not reachable".
        let models = OllamaSummarizationProvider.listInstalledModels(url: cfgState.ollamaUrl)
        let reachable = !models.isEmpty
        let displayURL = cfgState.ollamaUrl.replacingOccurrences(of: NSHomeDirectory(), with: "~")

        card.addRow(RowBuilder.row(
            label: "Ollama server",
            sub: reachable
                ? "Reachable at \(displayURL) — \(models.count) model\(models.count == 1 ? "" : "s") installed."
                : "Couldn't reach \(displayURL). Install Ollama and run `ollama serve`, or pull a model first.",
            leadingImage: OllamaIcon.templateImage(),
            leadingImageBare: true,
            control: StatusBadgeView(kind: reachable ? .ok : .warn,
                                     label: reachable ? "Reachable" : "Not reachable")))

        // URL row. Action fires on Enter or focus loss; on change we rebuild
        // the card so the model list and status badge re-probe.
        let urlField = ThemedTextField(string: cfgState.ollamaUrl)
        urlField.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let urlTarget = OllamaTextTarget { [weak self] in
            guard let self else { return }
            let v = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let next = v.isEmpty ? "http://localhost:11434" : v
            if next != self.cfgState.ollamaUrl {
                self.cfgState.ollamaUrl = next
                self.changes { c in c.ollamaUrl = next }
                self.refreshProviderCard()
            }
        }
        urlField.target = urlTarget
        urlField.action = #selector(OllamaTextTarget.fire)
        urlField.delegate = urlTarget
        objc_setAssociatedObject(urlField, &OllamaTextTarget.key, urlTarget, .OBJC_ASSOCIATION_RETAIN)
        card.addRow(RowBuilder.row(
            label: "Server URL",
            sub: "Defaults to a local Ollama install. Point this at a LAN host if you want a beefier Mac to do the summary.",
            control: urlField))

        // Model row. If we got a list from /api/tags, show a popup. If not,
        // fall back to a free-text field so the user can still type a name.
        if reachable {
            let popup = NSPopUpButton(frame: .zero, pullsDown: false)
            popup.addItems(withTitles: models)
            // If the configured model is in the list, select it. Otherwise
            // (empty default, or a previously-pulled model that's been removed)
            // pre-select the first one so saving without touching it picks
            // *something* that actually works.
            if !cfgState.ollamaModel.isEmpty, models.contains(cfgState.ollamaModel) {
                popup.selectItem(withTitle: cfgState.ollamaModel)
            } else if let first = models.first {
                popup.selectItem(withTitle: first)
                // Don't auto-save the user into a model they didn't pick —
                // wait for an explicit selection. But do keep cfgState in
                // sync so the prompt-disclosure copy reads sensibly.
            }
            let popupTarget = ToggleTarget { [weak self] in
                let title = popup.titleOfSelectedItem ?? ""
                self?.cfgState.ollamaModel = title
                self?.changes { c in c.ollamaModel = title }
            }
            popup.target = popupTarget
            popup.action = #selector(ToggleTarget.fire)
            objc_setAssociatedObject(popup, &ToggleTarget.key, popupTarget, .OBJC_ASSOCIATION_RETAIN)
            popup.widthAnchor.constraint(equalToConstant: 220).isActive = true
            card.addRow(RowBuilder.row(
                label: "Local model",
                sub: cfgState.ollamaModel.isEmpty
                    ? "Pick the model that writes the note. Bigger models follow the prompt better."
                    : "Used for every summary while Ollama is selected. Bigger models follow the prompt better.",
                control: popup), last: true)
        } else {
            let modelField = ThemedTextField(string: cfgState.ollamaModel)
            modelField.placeholderString = "llama3.1:8b"
            modelField.widthAnchor.constraint(equalToConstant: 220).isActive = true
            let modelTarget = OllamaTextTarget { [weak self] in
                guard let self else { return }
                let v = modelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if v != self.cfgState.ollamaModel {
                    self.cfgState.ollamaModel = v
                    self.changes { c in c.ollamaModel = v }
                }
            }
            modelField.target = modelTarget
            modelField.action = #selector(OllamaTextTarget.fire)
            modelField.delegate = modelTarget
            objc_setAssociatedObject(modelField, &OllamaTextTarget.key, modelTarget, .OBJC_ASSOCIATION_RETAIN)
            card.addRow(RowBuilder.row(
                label: "Local model",
                sub: "Ollama isn't reachable yet — type the model name you'll pull (`ollama pull <name>`), e.g. `llama3.1:8b`.",
                control: modelField), last: true)
        }
    }

    private func refreshAdvanced() {
        advContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard Disclosure.isOn else { return }
        let card = GroupCard(title: "Prompt")
        // The analyst prompt is hardcoded in SummarizerPrompt.swift, not in
        // config.json — surface it as informational with a badge that points
        // there, rather than an "Edit in config.json" button that would lead
        // users to a file that doesn't contain the prompt.
        card.addRow(RowBuilder.row(
            label: "How Ghostie asks for the note",
            sub: "Ghostie ships its own meeting-notes prompt and uses it with both providers, so notes have the same shape regardless of which model writes them.",
            control: StatusBadgeView(kind: .muted, label: "Built-in")),
                    last: true)
        advContainer.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: advContainer.widthAnchor).isActive = true
    }
}

/// `NSTextField` target/delegate so editing fires `fire()` both on Enter and
/// on focus loss (`sendsActionOnEndEditing` alone fires only when the user
/// commits — `controlTextDidEndEditing` covers the tab/click-away case too).
private final class OllamaTextTarget: NSObject, NSTextFieldDelegate {
    static var key: UInt8 = 0
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
    func controlTextDidEndEditing(_ obj: Notification) { block() }
}

/// `NSTextField` with explicit dark-mode-aware text + background colors.
/// A plain `NSTextField(string:)` resolves its background against the system
/// appearance at init time and doesn't repaint when the parent's effective
/// appearance flips — which is how the Ollama URL field ended up rendered in
/// light-mode white inside a dark-mode card. Subclassing lets us refresh on
/// `viewDidChangeEffectiveAppearance`.
private final class ThemedTextField: NSTextField {
    init(string: String) {
        super.init(frame: .zero)
        stringValue = string
        isBordered = true
        isBezeled = true
        bezelStyle = .roundedBezel
        isEditable = true
        isSelectable = true
        drawsBackground = true
        font = .systemFont(ofSize: 12.5)
        translatesAutoresizingMaskIntoConstraints = false
        applyTheme()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    private func applyTheme() {
        // `.textBackgroundColor` and `.labelColor` are system dynamic colors;
        // re-assigning here forces the field to drop its cached resolution
        // and pick up the current appearance.
        textColor = .labelColor
        backgroundColor = .textBackgroundColor
        needsDisplay = true
    }
}

// MARK: - Pane: Updates

private final class UpdatesPane: NSView {
    enum DisplayStatus {
        case unknown(version: String)
        case upToDate(version: String)
        case available(from: String, to: String, notes: String)
        case unsupported
        case failed(String)
    }

    private let cfg: Config
    private let onCheckNow: () -> Void
    private let changes: ((inout Config) -> Void) -> Void

    private let heroTile = NSView()
    /// Last hero-tile color, kept so a light/dark switch can re-resolve the
    /// `cgColor` snapshot without waiting for the next `show(status:)`.
    private var heroBg: NSColor = Theme.chipBg
    private func setHeroBg(_ c: NSColor) {
        heroBg = c
        heroTile.layer?.backgroundColor = themedCG(c)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        heroTile.layer?.backgroundColor = themedCG(heroBg)
    }
    private let heroSymbol = NSImageView()
    private let heroTitle = NSTextField(labelWithString: "")
    // Wrapping label — when the unsupported-build hero subtitle is set
    // ("This copy of Ghostie wasn't signed by us, so it can't update itself
    // safely. Grab the latest from the GitHub releases page."), a non-
    // wrapping label's intrinsic single-line width was pushing the entire
    // window wider on every visit to Updates.
    private let heroSub = NSTextField(wrappingLabelWithString: "")
    private let checkBtn: StyledButton

    init(cfg: Config, onCheckNow: @escaping () -> Void,
         changes: @escaping ((inout Config) -> Void) -> Void) {
        self.cfg = cfg
        self.onCheckNow = onCheckNow
        self.changes = changes
        self.checkBtn = StyledButton(title: "Check now", target: nil, action: nil)
        super.init(frame: .zero)
        build()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let header = PageHeaderView(title: "Updates",
                                    subtitle: "How Ghostie checks for new releases and how it verifies them before installing.")
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = GroupCard()
        let hero = NSView()
        hero.translatesAutoresizingMaskIntoConstraints = false
        heroTile.translatesAutoresizingMaskIntoConstraints = false
        heroTile.wantsLayer = true
        heroTile.layer?.cornerRadius = 10
        heroSymbol.translatesAutoresizingMaskIntoConstraints = false

        heroTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        heroTitle.textColor = Theme.text
        heroTitle.translatesAutoresizingMaskIntoConstraints = false

        heroSub.font = .systemFont(ofSize: 12)
        heroSub.textColor = Theme.text2
        heroSub.translatesAutoresizingMaskIntoConstraints = false
        heroSub.maximumNumberOfLines = 2
        heroSub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heroSub.setContentHuggingPriority(.defaultLow, for: .horizontal)

        heroTile.addSubview(heroSymbol)
        let textStack = NSStackView(views: [heroTitle, heroSub])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let checkTarget = ActionTarget { [weak self] in self?.onCheckNow() }
        checkBtn.target = checkTarget
        checkBtn.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(checkBtn, &ActionTarget.key, checkTarget, .OBJC_ASSOCIATION_RETAIN)

        hero.addSubview(heroTile)
        hero.addSubview(textStack)
        hero.addSubview(checkBtn)
        NSLayoutConstraint.activate([
            heroTile.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 14),
            heroTile.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
            heroTile.widthAnchor.constraint(equalToConstant: 44),
            heroTile.heightAnchor.constraint(equalToConstant: 44),
            heroSymbol.centerXAnchor.constraint(equalTo: heroTile.centerXAnchor),
            heroSymbol.centerYAnchor.constraint(equalTo: heroTile.centerYAnchor),
            heroSymbol.widthAnchor.constraint(equalToConstant: 22),
            heroSymbol.heightAnchor.constraint(equalToConstant: 22),
            textStack.leadingAnchor.constraint(equalTo: heroTile.trailingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: checkBtn.leadingAnchor, constant: -12),
            checkBtn.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -14),
            checkBtn.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
            hero.topAnchor.constraint(equalTo: heroTile.topAnchor, constant: -14),
            hero.bottomAnchor.constraint(equalTo: heroTile.bottomAnchor, constant: 14)
        ])
        card.addRow(hero)

        card.addRow(buildToggleRow(
            label: "Check on its own",
            sub: "Ghostie peeks at GitHub about once a day and just after launch.",
            on: cfg.autoCheckUpdates) { [weak self] on in
                self?.changes { c in c.autoCheckUpdates = on }
            })
        card.addRow(buildStartAtLoginRow(), last: true)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Initial state — no GitHub round-trip happens on window open, so
        // don't claim "You're up to date". Show the running version with a
        // neutral prompt to check; the user clicks Check now to verify.
        if Updater.runningBuildSupportsOTA() {
            show(status: .unknown(version: "\(Updater.runningVersion())"))
        } else {
            show(status: .unsupported)
        }
    }

    private func buildToggleRow(label: String, sub: String, on: Bool,
                                onChange: @escaping (Bool) -> Void) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = on ? .on : .off
        let target = ToggleTarget { onChange(toggle.state == .on) }
        toggle.target = target
        toggle.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(toggle, &ToggleTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return RowBuilder.row(label: label, sub: sub, control: toggle)
    }

    private func buildStartAtLoginRow() -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        if #available(macOS 13.0, *) {
            toggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
        let target = ToggleTarget {
            guard #available(macOS 13.0, *) else { return }
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                let a = NSAlert()
                a.messageText = "Could not change login item"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
            if #available(macOS 13.0, *) {
                toggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            }
        }
        toggle.target = target
        toggle.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(toggle, &ToggleTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return RowBuilder.row(
            label: "Open Ghostie when I log in",
            sub: "Skip the manual launch — Ghostie comes back to the menu bar every time you sign in.",
            control: toggle)
    }

    func setBusy(_ busy: Bool, statusText: String?) {
        checkBtn.isEnabled = !busy
        if let statusText {
            heroSub.stringValue = statusText
        }
    }

    func show(status: DisplayStatus) {
        switch status {
        case .unknown(let v):
            setHeroBg(Theme.chipBg)
            heroSymbol.image = NSImage(systemSymbolName: "arrow.clockwise",
                                       accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
            heroSymbol.contentTintColor = Theme.text2
            heroTitle.stringValue = "Ghostie \(v)"
            heroSub.stringValue = "Click Check now to see if there's a newer release."
            checkBtn.title = "Check now"
        case .upToDate(let v):
            setHeroBg(Theme.okSoft)
            heroSymbol.image = NSImage(systemSymbolName: "checkmark",
                                       accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
            heroSymbol.contentTintColor = Theme.ok
            heroTitle.stringValue = "You're on the latest"
            heroSub.stringValue = "Ghostie \(v)"
            checkBtn.title = "Check now"
        case .available(let from, let to, _):
            setHeroBg(Theme.infoSoft)
            heroSymbol.image = NSImage(systemSymbolName: "arrow.down.circle",
                                       accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
            heroSymbol.contentTintColor = Theme.info
            heroTitle.stringValue = "A new version is ready"
            heroSub.stringValue = "\(from) → \(to)"
            checkBtn.title = "Update"
        case .unsupported:
            setHeroBg(Theme.warnSoft)
            heroSymbol.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                       accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
            heroSymbol.contentTintColor = Theme.warn
            heroTitle.stringValue = "Can't update from here"
            heroSub.stringValue = "This copy of Ghostie wasn't signed by us, so it can't update itself safely. Grab the latest from the GitHub releases page."
            checkBtn.title = "Open Releases"
            // Repoint to releases page when the build can't OTA.
            let target = ActionTarget {
                NSWorkspace.shared.open(Updater.releasesPage)
            }
            checkBtn.target = target
            checkBtn.action = #selector(ActionTarget.fire)
            objc_setAssociatedObject(checkBtn, &ActionTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        case .failed(let e):
            setHeroBg(Theme.dangerSoft)
            heroSymbol.image = NSImage(systemSymbolName: "xmark.circle",
                                       accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
            heroSymbol.contentTintColor = Theme.danger
            heroTitle.stringValue = "Couldn't reach GitHub"
            heroSub.stringValue = e
            checkBtn.title = "Try again"
        }
    }
}

// MARK: - Pane: Advanced

private final class AdvancedPane: NSView {
    init(openConfig: @escaping () -> Void,
         revealData: @escaping () -> Void,
         runDiagnose: @escaping () -> Void,
         runSelftest: @escaping () -> Void,
         runDoctor: @escaping () -> Void,
         resetSettings: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let header = PageHeaderView(title: "Developer",
                                    subtitle: "Where Ghostie keeps its files and how to poke at it from the terminal. Most people won't need anything here.")
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = GroupCard()
        card.addRow(rowWithButton(label: "Open the config file",
                                  sub: "~/.ghostie/config.json — every setting Ghostie remembers, in one editable file.",
                                  symbol: "doc.text",
                                  button: ("Open", .secondary, openConfig)))
        card.addRow(rowWithButton(label: "Show me the Ghostie folder",
                                  sub: "~/.ghostie — where models, queued calls, and recordings live.",
                                  symbol: "folder",
                                  button: ("Reveal", .secondary, revealData)))
        card.addRow(rowWithButton(label: "Watch the detector live",
                                  sub: "Opens a terminal and streams what Ghostie sees while deciding if a call is real.",
                                  symbol: "terminal",
                                  button: ("Run", .secondary, runDiagnose)))
        card.addRow(rowWithButton(label: "Run a health check",
                                  sub: "Opens a terminal and reports whether Whisper, Claude and the permissions are all set up.",
                                  symbol: "stethoscope",
                                  button: ("Run", .secondary, runDoctor)))
        card.addRow(rowWithButton(label: "Run the self-test",
                                  sub: "Opens a terminal and replays the internal regression suite. Useful after editing Ghostie.",
                                  symbol: "checkmark.shield",
                                  button: ("Run", .secondary, runSelftest)))
        card.addRow(rowWithButton(label: "Reset all settings",
                                  sub: "Puts every setting back to its default. Your notes, the queue, and downloaded models stay.",
                                  symbol: nil,
                                  danger: true,
                                  button: ("Reset…", .danger, resetSettings)), last: true)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rowWithButton(label: String, sub: String,
                               symbol: String?,
                               danger: Bool = false,
                               button: (title: String, kind: ButtonKind, action: () -> Void))
        -> NSView {
        let target = ActionTarget { button.action() }
        let b = StyledButton(title: button.title, target: target, action: #selector(ActionTarget.fire))
        b.kind = button.kind
        objc_setAssociatedObject(b, &ActionTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return RowBuilder.row(label: label, sub: sub,
                              leadingSymbol: symbol,
                              leadingTint: symbol == nil ? nil : Theme.text2,
                              control: b, danger: danger)
    }
}

// MARK: - Pane: About

private final class AboutPane: NSView {
    init(openReleases: @escaping () -> Void) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let header = PageHeaderView(title: "About Ghostie",
                                    subtitle: "What Ghostie does, what's running on this Mac, and the licences it ships with.")
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = GroupCard()
        let v = "\(Updater.runningVersion())"
        let signed = Updater.runningBuildSupportsOTA()
        let macVer = ProcessInfo.processInfo.operatingSystemVersionString
        card.addRow(RowBuilder.row(
            label: "Version",
            sub: signed ? "\(v) · official signed release"
                        : "\(v) · built from source",
            control: NSTextField(labelWithString: v).styledAsMono()))
        card.addRow(RowBuilder.row(
            label: "macOS", sub: macVer,
            control: StatusBadgeView(kind: .ok, label: "Supported")))
        let target = ActionTarget(openReleases)
        let btn = StyledButton(title: "Open releases", target: target,
                               action: #selector(ActionTarget.fire))
        objc_setAssociatedObject(btn, &ActionTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        card.addRow(RowBuilder.row(
            label: "Open-source bits",
            sub: "Ghostie itself is MIT. It stands on Whisper.cpp (MIT), KB-Whisper (Apache 2.0), and Silero VAD (MIT).",
            control: btn), last: true)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Misc helpers

private extension NSTextField {
    /// Style a static label with the monospace font used for paths / sizes.
    func styledAsMono() -> NSTextField {
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textColor = Theme.text2
        return self
    }
}
