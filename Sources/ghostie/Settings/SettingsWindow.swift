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
            if case .missing = ModelDownloader.health(for: [m], verifyHash: false)[0].state {
                startDownload(m, key: key)
                return
            }
        }
    }

    /// Row keys are catalog filenames now (globally unique, already the
    /// download/sidecar key), so a `Model` maps straight to its row.
    private func rowKey(for model: Model) -> String? { model.filename }

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
        // The Listening pane's per-second tick mirrors the sidebar tick: stop
        // it here, not in its deinit — the pane can outlive the window.
        panes.listening?.stopLiveTick()
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
                addModel: { [weak self] in self?.presentAddModelSheet() },
                removeModel: { [weak self] key in self?.removeModel(key) },
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

    /// Resolve the row key (a catalog filename) to the Model it represents.
    fileprivate func modelForKey(_ key: String) -> Model? {
        ModelCatalog.load().first { $0.filename == key }?.model()
    }

    private func handleModelRowAction(_ key: String) {
        guard let model = modelForKey(key) else { return }
        // Hash-free check (SHA256 of a ~1.1 GB file is ~3 s on the main
        // thread). A hash mismatch is only ever discovered by the explicit
        // Verify/Re-verify actions below, so overlay the pane's remembered
        // verdict — it's the state the row is actually displaying.
        var state = ModelDownloader.health(for: [model], verifyHash: false)[0].state
        if case .ok = state, let verdict = panes.transcription?.verifiedState(key) {
            state = verdict
        }
        switch state {
        case .missing, .sizeWrong, .hashMismatch:
            if inflightModelKey == key {
                downloader.cancel()
                inflightModelKey = nil
                panes.transcription?.downloadDidSettle(key)
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
            self.panes.transcription?.downloadDidSettle(key)
        })
    }

    /// Remove a model from the list: confirm, cancel any in-flight download,
    /// delete the file + sidecar, drop a custom catalog entry (built-ins stay
    /// as re-addable presets), and rebuild. The language self-heals out of the
    /// effective whitelist once its model is gone.
    private func removeModel(_ key: String) {
        guard let model = modelForKey(key) else { return }
        let entry = ModelCatalog.load().first { $0.filename == key }
        let a = NSAlert()
        a.messageText = "Remove this model?"
        a.informativeText = "Deletes \(key) from ~/.ghostie/models."
            + ((entry?.builtin ?? false) ? " You can re-add it later from the + menu." : "")
        a.addButton(withTitle: "Remove")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        if inflightModelKey == key { downloader.cancel(); inflightModelKey = nil }
        try? FileManager.default.removeItem(atPath: model.destPath)
        try? FileManager.default.removeItem(atPath: model.sidecarPath)
        if entry?.builtin == false { ModelCatalog.remove(filename: key) }
        panes.transcription?.downloadDidSettle(key)
    }

    private func startAdopt(_ model: Model, key: String) {
        guard inflightModelKey == nil else { return }
        panes.transcription?.setRowBusy(key, status: "Verifying (HEAD + SHA256)…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = ModelDownloader.adopt(model)
            DispatchQueue.main.async {
                self?.panes.transcription?.recordVerifiedState(state, forKey: key)
            }
        }
    }

    private func startReverify(_ model: Model, key: String) {
        guard inflightModelKey == nil else { return }
        panes.transcription?.setRowBusy(key, status: "Re-hashing…")
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let state = ModelDownloader.health(for: [model])[0].state
            DispatchQueue.main.async {
                self?.panes.transcription?.recordVerifiedState(state, forKey: key)
            }
        }
    }

    /// "Add a model" form: paste a Hugging Face repo, pick the language. Ghostie
    /// finds the GGML file in the repo (HF API), writes the pairing to
    /// `~/.ghostie/models.json` via `ModelCatalog`, and downloads it — the rest
    /// of the pipeline (detection → per-language decode) picks it up with no
    /// further config because the disk is the language whitelist.
    private func presentAddModelSheet() {
        func field(_ placeholder: String, width: CGFloat) -> NSTextField {
            let f = NSTextField(string: "")
            f.placeholderString = placeholder
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: width).isActive = true
            return f
        }
        func lbl(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.alignment = .right
            return t
        }
        let repoField = field("KBLab/kb-whisper-large", width: 340)
        let langField = field("ar", width: 120)
        let grid = NSGridView(views: [
            [lbl("Hugging Face repo"), repoField],
            [lbl("Language"),          langField]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 78))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        let a = NSAlert()
        a.messageText = "Add a model"
        a.informativeText = "Paste a Hugging Face repo (org/name) — Ghostie finds the model file and downloads it. The language is the code Ghostie should use this model for (e.g. ar, de, fr); it detects each speaker's language and routes it to the matching model."
        a.addButton(withTitle: "Add & Download")
        a.addButton(withTitle: "Cancel")
        a.accessoryView = container
        a.window.initialFirstResponder = repoField
        guard a.runModal() == .alertFirstButtonReturn else { return }

        let raw = repoField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let lang = langField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func fail(_ msg: String) {
            let e = NSAlert()
            e.alertStyle = .warning
            e.messageText = "Couldn't add the model"
            e.informativeText = msg
            e.runModal()
        }
        guard !raw.isEmpty else {
            fail("Enter a Hugging Face repo, like KBLab/kb-whisper-large.")
            return
        }

        // Resolving the file may hit the HF API — do it off the main thread, then
        // add + download (or report a clear error) back on main.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resolved = HuggingFace.resolve(raw)
            DispatchQueue.main.async {
                guard let self else { return }
                guard let r = resolved, !r.filename.isEmpty else {
                    fail("Couldn't find a model file in “\(raw)”. Check the repo name, or paste the direct file URL from Hugging Face.")
                    return
                }
                // Friendly label: the repo's last path component, else the filename.
                let label = (!raw.lowercased().hasPrefix("http") && raw.contains("/"))
                    ? (raw.split(separator: "/").last.map(String.init) ?? r.filename)
                    : (r.filename as NSString).deletingPathExtension
                let entry = CatalogEntry(filename: r.filename, url: r.url, label: label,
                                         language: lang, goodForLID: false,
                                         approxBytes: 0, builtin: false)
                ModelCatalog.add(entry)
                // If the user has an explicit language whitelist (e.g. migrated
                // from the old sv↔en toggle, which persisted ["sv","en"]), grow it
                // so the new language activates — otherwise effectiveLanguages
                // would silently drop it. Disk-driven users (empty list) need no
                // change; the disk is the whitelist.
                if !lang.isEmpty {
                    self.mutateCfg { c in
                        if !c.codeSwitch.languages.isEmpty, !c.codeSwitch.languages.contains(lang) {
                            c.codeSwitch.languages.append(lang)
                        }
                    }
                }
                self.panes.transcription?.applyConfig(self.cfg)
                // Kick off the download (health is .missing → startDownload).
                self.handleModelRowAction(r.filename)
            }
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

enum PaneId: String, CaseIterable {
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

