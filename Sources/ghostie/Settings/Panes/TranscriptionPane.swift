import AppKit
import QuartzCore

// MARK: - Pane: Transcription

final class TranscriptionPane: NSView {

    private struct ModelRowState {
        let row: ModelRowView
        let key: String
    }

    private var cfg: Config
    private let rowAction: (String) -> Void
    private let openConfig: () -> Void
    private let addModel: () -> Void
    private let removeModel: (String) -> Void
    private let parentChanges: ((inout Config) -> Void) -> Void
    private let advContainer = NSStackView()
    private var rows: [String: ModelRowState] = [:]
    /// The catalog entry behind each row, keyed by filename — so refresh logic
    /// reads language/goodForLID without re-loading the catalog per row.
    private var entriesByKey: [String: CatalogEntry] = [:]
    private let modelsCard = GroupCard(title: "Models")
    private let languagesCard = GroupCard(title: "Languages")
    /// The row selected for the `−` button.
    private var selectedKey: String?
    /// Built-in presets whose download is in flight — shown in the list while
    /// downloading even though they're not on disk yet. Pruned when the
    /// download settles (see `downloadDidSettle`).
    private var pendingKeys: Set<String> = []
    /// Full-hash verdicts from the explicit Verify / Re-verify row actions,
    /// keyed by row. Routine refreshes skip the SHA256 (existence + sidecar
    /// size only — hashing ~1.1 GB on the main thread froze the pane), so a
    /// hash mismatch can only be discovered by those actions; remember it
    /// here so the badge and the action button keep reporting it until a
    /// re-download settles.
    private var verifiedStates: [String: ModelDownloader.HealthState] = [:]
    private weak var footerSeg: NSSegmentedControl?
    /// Retains the `+` menu's action target while the menu is open.
    private var menuTarget: MenuTarget?
    private var disclosureToken: NSObjectProtocol?

    init(cfg: Config,
         rowAction: @escaping (String) -> Void,
         openConfig: @escaping () -> Void,
         addModel: @escaping () -> Void,
         removeModel: @escaping (String) -> Void,
         changes: @escaping ((inout Config) -> Void) -> Void) {
        self.cfg = cfg
        self.rowAction = rowAction
        self.openConfig = openConfig
        self.addModel = addModel
        self.removeModel = removeModel
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

        // Languages — one checkbox per language the installed models can
        // decode (plus any explicitly-configured language whose model is
        // missing, flagged). The disk still drives what's *possible*; the
        // checkboxes edit `codeSwitch.languages`, the explicit whitelist.
        stack.addArrangedSubview(languagesCard)
        languagesCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rebuildLanguageRows()

        // Models — one row per catalog entry (built-ins + custom) plus an
        // "Add a model" button. Rebuilt whenever the catalog changes.
        stack.addArrangedSubview(modelsCard)
        modelsCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        rebuildModelRows()

        // Quality.
        let quality = GroupCard(title: "Quality")
        let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        qualityPopup.addItems(withTitles: ["Best quality", "Balanced (lighter)"])
        qualityPopup.selectItem(at: cfg.transcriptionQuality == "balanced" ? 1 : 0)
        let qualityTarget = ToggleTarget { [weak self] in
            let next = (qualityPopup.indexOfSelectedItem == 1) ? "balanced" : "best"
            guard let self, self.cfg.transcriptionQuality != next else { return }
            self.change { c in c.transcriptionQuality = next }
            // The single-language model is resolved from disk at load, not
            // persisted, so re-read the effective pick — the tickmark on the
            // model rows tracks it whenever code-switching isn't active.
            self.cfg.whisperModel = Config.load().whisperModel
            self.refreshAllRows()
        }
        qualityPopup.target = qualityTarget
        qualityPopup.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(qualityPopup, &ToggleTarget.key, qualityTarget, .OBJC_ASSOCIATION_RETAIN)
        qualityPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
        quality.addRow(RowBuilder.row(
            label: "Model for one-language calls",
            sub: "Balanced uses a smaller model — lighter on CPU, slightly less accurate.",
            control: qualityPopup))
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
        // One editable starter sentence per active code-switching language
        // (followup #5: only sv/en were reachable before; a third language's
        // prompts entry had no UI). Writes codeSwitch.prompts[lang]; an
        // emptied field removes the key.
        let installed = Models.installed(preferredKBVariant: cfg.codeSwitch.kbWhisperVariant)
        for lang in cfg.codeSwitch.effectiveLanguages(installed: installed) {
            let name = Locale.current.localizedString(forLanguageCode: lang) ?? lang
            let field = NSTextField(string: cfg.codeSwitch.prompts[lang] ?? "")
            field.placeholderString = "Optional — terms and style for \(name)"
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            field.cell?.sendsActionOnEndEditing = true
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            let target = ToggleTarget { [weak self, weak field] in
                guard let self, let field else { return }
                let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self.change { c in
                    if v.isEmpty { c.codeSwitch.prompts.removeValue(forKey: lang) }
                    else { c.codeSwitch.prompts[lang] = v }
                }
            }
            field.target = target
            field.action = #selector(ToggleTarget.fire)
            objc_setAssociatedObject(field, &ToggleTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
            card.addRow(RowBuilder.row(
                label: "Starter sentence (\(name))",
                sub: "Biases punctuation and vocabulary when decoding \(name) segments.",
                control: field))
        }
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

    /// Refresh the pane's cached config (e.g. after the Add-a-model flow grew
    /// the language whitelist) and rebuild the model rows + languages summary.
    func applyConfig(_ newCfg: Config) {
        cfg = newCfg
        rebuildModelRows()
    }

    /// Rebuild the Models card: a row per *installed* model (on disk, a built-in
    /// preset whose download is in flight, or any custom entry), an empty-state
    /// line when there are none, and a `+ −` footer — the macOS list-with-toolbar
    /// pattern. `+` opens a menu of predefined models (plus "Add from Hugging
    /// Face…"); `−` removes the selected row. Keeping the pane instance stable
    /// means an inflight download's row keeps updating across the rebuild.
    func rebuildModelRows() {
        modelsCard.clearRows()
        rows.removeAll()
        entriesByKey.removeAll()

        let fm = FileManager.default
        let listed = ModelCatalog.load().filter { e in
            guard let m = e.model() else { return false }
            return !e.builtin || fm.fileExists(atPath: m.destPath) || pendingKeys.contains(e.filename)
        }
        if listed.isEmpty {
            modelsCard.addRow(RowBuilder.row(
                label: "No models added yet",
                sub: "Click the + below to add one."))
        } else {
            for e in listed {
                entriesByKey[e.filename] = e
                let key = e.filename
                let row = ModelRowView(key: key, title: e.label, subtitle: subtitle(for: e))
                row.onAction = { [weak self] in self?.rowAction(key) }
                row.onSelect = { [weak self] in self?.select(key) }
                modelsCard.addRow(row)
                rows[key] = ModelRowState(row: row, key: key)
            }
        }
        modelsCard.addRow(buildModelsFooter(), last: true)

        if let sel = selectedKey, rows[sel] == nil { selectedKey = nil }
        refreshAllRows()
        if let sel = selectedKey { rows[sel]?.row.setHighlighted(true) }
    }

    /// The `+ −` toolbar beneath the model list.
    private func buildModelsFooter() -> NSView {
        let seg = NSSegmentedControl()
        seg.segmentStyle = .smallSquare
        seg.trackingMode = .momentary
        seg.segmentCount = 2
        seg.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Add"), forSegment: 0)
        seg.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove"), forSegment: 1)
        seg.setWidth(34, forSegment: 0)
        seg.setWidth(34, forSegment: 1)
        seg.setEnabled(selectedKey != nil, forSegment: 1)
        seg.translatesAutoresizingMaskIntoConstraints = false
        let target = ActionTarget { [weak self, weak seg] in
            guard let self, let seg else { return }
            if seg.selectedSegment == 0 { self.showAddMenu(from: seg) }
            else if let sel = self.selectedKey { self.removeModel(sel) }
        }
        seg.target = target
        seg.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(seg, &ActionTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        footerSeg = seg

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(seg)
        NSLayoutConstraint.activate([
            seg.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            seg.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            seg.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            seg.heightAnchor.constraint(equalToConstant: 22)
        ])
        return container
    }

    private func select(_ key: String) {
        selectedKey = key
        for (k, st) in rows { st.row.setHighlighted(k == key) }
        footerSeg?.setEnabled(true, forSegment: 1)
    }

    /// `+` menu: predefined models not yet installed, then "Add from Hugging Face…".
    private func showAddMenu(from view: NSView) {
        let fm = FileManager.default
        let presets = ModelCatalog.load().filter { e in
            guard e.builtin, let m = e.model() else { return false }
            return !fm.fileExists(atPath: m.destPath) && !pendingKeys.contains(e.filename)
        }
        let menu = NSMenu()
        let target = MenuTarget { [weak self] item in
            guard let self else { return }
            if let fn = item.representedObject as? String { self.startPreset(fn) }
            else { self.addModel() }
        }
        menuTarget = target
        for e in presets {
            let it = NSMenuItem(title: e.label, action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            it.representedObject = e.filename
            it.target = target
            menu.addItem(it)
        }
        if !presets.isEmpty { menu.addItem(.separator()) }
        let custom = NSMenuItem(title: "Add from Hugging Face…",
                                action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
        custom.target = target
        menu.addItem(custom)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    /// Add a built-in preset: show its row immediately (pending), grow the
    /// language whitelist if the user keeps an explicit one, then download.
    private func startPreset(_ filename: String) {
        pendingKeys.insert(filename)
        if let lang = ModelCatalog.load().first(where: { $0.filename == filename })?.language,
           !lang.isEmpty {
            change { c in
                if !c.codeSwitch.languages.isEmpty, !c.codeSwitch.languages.contains(lang) {
                    c.codeSwitch.languages.append(lang)
                }
            }
        }
        rebuildModelRows()
        rowAction(filename)   // → handleModelRowAction → startDownload (.missing)
    }

    /// A download settled (finished / failed / cancelled): drop it from the
    /// pending set and rebuild so a failed preset disappears and a finished one
    /// stays, shown by its on-disk status.
    func downloadDidSettle(_ key: String) {
        pendingKeys.remove(key)
        verifiedStates[key] = nil   // file replaced or removed — verdict is stale
        rebuildModelRows()
    }

    /// Last full-hash verdict for a row, if an explicit Verify / Re-verify
    /// has run. The hash-free refresh path can't tell ok from hashMismatch.
    func verifiedState(_ key: String) -> ModelDownloader.HealthState? {
        verifiedStates[key]
    }

    /// Land the result of an off-main Verify / Re-verify: remember the
    /// verdict (see `verifiedStates`) and redraw the row with it.
    func recordVerifiedState(_ state: ModelDownloader.HealthState, forKey key: String) {
        verifiedStates[key] = state
        refreshRow(key)
    }

    /// One-line description per catalog entry: the language it decodes (and
    /// whether it also drives detection), or a VAD note for the VAD entry.
    private func subtitle(for e: CatalogEntry) -> String {
        if e.language.isEmpty {
            return "Voice activity — lets Ghostie skip silent stretches so it doesn't invent words."
        }
        let base = "Decodes ‘\(e.language)’."
        return e.goodForLID ? base + " Also drives language detection." : base
    }

    /// One checkbox row per language: everything the installed models decode,
    /// plus any explicit `codeSwitch.languages` entry whose model is missing
    /// (kept visible with a warning so the user sees why it can't decode).
    /// Followup #5: the old binary mode popup couldn't express N languages.
    private func rebuildLanguageRows() {
        languagesCard.clearRows()
        let installed = Models.installed(preferredKBVariant: cfg.codeSwitch.kbWhisperVariant)
        let onDisk = installed.languages
        let all = Set(onDisk).union(cfg.codeSwitch.languages).sorted()
        let active = Set(cfg.codeSwitch.effectiveLanguages(installed: installed))
        guard !all.isEmpty else {
            languagesCard.addRow(RowBuilder.row(
                label: "No languages yet",
                sub: "Download a model below — Ghostie recognizes whatever languages the installed models decode, and routes each speaker to the matching model.",
                control: NSView()), last: true)
            return
        }
        for (i, lang) in all.enumerated() {
            let missing = !onDisk.contains(lang)
            let name = Locale.current.localizedString(forLanguageCode: lang) ?? lang
            let box = NSButton(checkboxWithTitle: "", target: nil, action: nil)
            box.state = active.contains(lang) || (missing && cfg.codeSwitch.languages.contains(lang))
                ? .on : .off
            let target = ToggleTarget { [weak self, weak box] in
                guard let self, let box else { return }
                self.toggleLanguage(lang, on: box.state == .on)
            }
            box.target = target
            box.action = #selector(ToggleTarget.fire)
            objc_setAssociatedObject(box, &ToggleTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
            languagesCard.addRow(RowBuilder.row(
                label: "\(name) (\(lang))",
                sub: missing
                    ? "Configured, but its model isn't installed — add one below or uncheck."
                    : "Ghostie detects when a speaker uses \(name) and routes it to the matching model.",
                control: box), last: i == all.count - 1)
        }
    }

    /// Write the new selection to `codeSwitch.languages` — an explicit
    /// whitelist, exactly what the old popup's one-liner wrote. Never allowed
    /// to go empty (an empty list means "everything installed", so unchecking
    /// the last language would paradoxically re-enable them all).
    private func toggleLanguage(_ lang: String, on: Bool) {
        let installed = Models.installed(preferredKBVariant: cfg.codeSwitch.kbWhisperVariant)
        var selection = Set(cfg.codeSwitch.languages.isEmpty
            ? cfg.codeSwitch.effectiveLanguages(installed: installed)
            : cfg.codeSwitch.languages)
        if on { selection.insert(lang) } else { selection.remove(lang) }
        guard !selection.isEmpty else {
            rebuildLanguageRows()   // restore the checkbox; refuse the edit
            return
        }
        change { c in c.codeSwitch.languages = selection.sorted() }
        refreshAdvanced()   // per-language prompt fields track the selection
        refreshAllRows()    // model-row tickmarks + language rows
    }

    func refreshRow(_ key: String) {
        guard let st = rows[key], let model = modelForKey(key), let e = entriesByKey[key] else { return }
        // Hash-free: this runs on pane build and every refresh, and a SHA256
        // of a ~1.1 GB model is ~3 s on the main thread. A mismatch verdict
        // from an explicit Verify / Re-verify overlays the cheap check.
        var state = ModelDownloader.health(for: [model], verifyHash: false)[0].state
        if case .ok = state, let verdict = verifiedStates[key] { state = verdict }
        let installed = Models.installed(preferredKBVariant: cfg.codeSwitch.kbWhisperVariant)
        let active = cfg.codeSwitch.effectiveLanguages(installed: installed)
        let selected: Bool
        if e.language.isEmpty {
            // VAD: no explicit toggle — whisper-cli uses it automatically
            // whenever the file is on disk. Tick it when present.
            selected = state.isOK
        } else if active.count < 2 {
            // Single-language path: the one model the engine will actually use.
            selected = (model.destPath == cfg.whisperModel)
        } else {
            // Multi-language: a model is "active" when its language is in the
            // effective whitelist — it's the decoder for that language.
            selected = active.contains(e.language)
        }
        st.row.apply(state: state, selected: selected, isPaired: false)
    }

    func refreshAllRows() {
        for key in rows.keys { refreshRow(key) }
        rebuildLanguageRows()
    }

    func setRowDownloading(_ key: String, percent: Double, status: String) {
        rows[key]?.row.setDownloading(percent: percent, status: status)
    }
    func setRowBusy(_ key: String, status: String) {
        rows[key]?.row.setBusy(status: status)
    }

    private func modelForKey(_ key: String) -> Model? {
        entriesByKey[key]?.model()
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

/// Block-based target for `NSMenuItem`s in the "+" menu — the item is passed
/// back so the handler can read its `representedObject`.
private final class MenuTarget: NSObject {
    private let handler: (NSMenuItem) -> Void
    init(_ handler: @escaping (NSMenuItem) -> Void) { self.handler = handler }
    @objc func fire(_ sender: NSMenuItem) { handler(sender) }
}

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
    /// Click anywhere on the row (not the action button) to select it for the
    /// `−` button — the macOS list pattern.
    var onSelect: (() -> Void)?

    init(key: String, title: String, subtitle: String) {
        self.action = StyledButton(title: "Download", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        // Click anywhere on the row (a gesture recognizer fires even over the
        // non-interactive labels, which would otherwise swallow `mouseDown`).
        // Don't delay primary mouse events, so the action button still works.
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)

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

    @objc private func rowClicked() { onSelect?() }

    func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on ? Theme.accent.withAlphaComponent(0.14).cgColor
                                    : NSColor.clear.cgColor
    }

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
