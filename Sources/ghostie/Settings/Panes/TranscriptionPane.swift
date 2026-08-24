import AppKit
import QuartzCore

// MARK: - Pane: Transcription

/// v3: one **language-primary** list replaces the old pair of cards (a
/// checkbox list of languages *and* a `+ −` list of models) that described the
/// same thing from two directions and had to be kept in sync by hand.
///
/// The pane is render-only. Everything it draws comes from one
/// `LanguageSetup.resolve(...)` — the same computation `doctor` prints and the
/// pipeline obeys — so there is no longer a refresh graph
/// (`rebuildModelRows` → `refreshAllRows` → `rebuildLanguageRows` → …) to keep
/// consistent by remembering to call things in the right order.
final class TranscriptionPane: NSView {

    private var cfg: Config
    private let openConfig: () -> Void
    private let addLanguage: () -> Void
    private let removeLanguage: (String) -> Void
    private let changeModel: (String) -> Void
    private let setPrimary: (String) -> Void
    private let downloadModel: (String) -> Void
    private let parentChanges: ((inout Config) -> Void) -> Void

    private let languagesCard = GroupCard(title: "Languages")
    private let advContainer = NSStackView()
    private var qualityCard: GroupCard?
    private let qualityContainer = NSStackView()

    /// The resolved state currently on screen. Recomputed on every rebuild;
    /// nothing else caches a slice of it.
    private var setup: LanguageSetup

    /// Language rows by code, so an in-flight download can update one row
    /// without a rebuild (a rebuild mid-download would drop the progress bar).
    private var rows: [String: LanguageRowView] = [:]
    /// The row selected for the `−` button.
    private var selectedCode: String?
    private weak var footerSeg: NSSegmentedControl?
    private var menuTarget: MenuTarget?
    private var disclosureToken: NSObjectProtocol?

    init(cfg: Config,
         openConfig: @escaping () -> Void,
         addLanguage: @escaping () -> Void,
         removeLanguage: @escaping (String) -> Void,
         changeModel: @escaping (String) -> Void,
         setPrimary: @escaping (String) -> Void,
         downloadModel: @escaping (String) -> Void,
         changes: @escaping ((inout Config) -> Void) -> Void) {
        self.cfg = cfg
        self.openConfig = openConfig
        self.addLanguage = addLanguage
        self.removeLanguage = removeLanguage
        self.changeModel = changeModel
        self.setPrimary = setPrimary
        self.downloadModel = downloadModel
        self.parentChanges = changes
        self.setup = LanguageSetup.resolve(config: cfg)
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

    /// Apply a config mutation locally and to the persisted config in one step.
    /// The pane caches `cfg` so a rebuild reads coherent state without going
    /// back to disk.
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
        let header = PageHeaderView(
            title: "Transcription",
            subtitle: "The languages Ghostie should understand, and the model it runs locally for each one.")
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        stack.addArrangedSubview(languagesCard)
        languagesCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Quality lives in its own container because one of its rows only
        // applies in single-language mode and has to appear/disappear with it.
        qualityContainer.orientation = .vertical
        qualityContainer.alignment = .leading
        qualityContainer.spacing = 22
        qualityContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(qualityContainer)
        qualityContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        advContainer.orientation = .vertical
        advContainer.alignment = .leading
        advContainer.spacing = 22
        advContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(advContainer)
        advContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        rebuild()
    }

    /// Recompute and redraw everything. The single refresh entry point — there
    /// is deliberately no partial variant, because the old pane's four partial
    /// refreshers were where the drift lived.
    func rebuild() {
        setup = LanguageSetup.resolve(config: cfg)
        rebuildLanguages()
        rebuildQuality()
        refreshAdvanced()
    }

    /// Adopt a config edited elsewhere (the add-language sheet) and redraw.
    func applyConfig(_ newCfg: Config) {
        cfg = newCfg
        rebuild()
    }

    // MARK: Languages card

    private func rebuildLanguages() {
        languagesCard.clearRows()
        rows.removeAll()

        if setup.rows.isEmpty {
            languagesCard.addRow(RowBuilder.row(
                label: "No languages yet",
                sub: "Add the languages you speak on calls. Ghostie downloads a model for each one and detects which is being spoken, per speaker."))
        } else {
            for r in setup.rows {
                let row = LanguageRowView(row: r)
                row.onSelect = { [weak self] in self?.select(r.code) }
                row.onMenu = { [weak self] view in self?.showRowMenu(for: r, from: view) }
                row.onAction = { [weak self] in
                    guard let self else { return }
                    switch r.state {
                    case .missing: if let f = r.modelFilename { self.downloadModel(f) }
                    case .none:    self.changeModel(r.code)
                    case .onDisk:  break
                    }
                }
                languagesCard.addRow(row)
                rows[r.code] = row
            }
        }

        // What the pipeline will actually do, stated in words. The
        // single↔code-switch boundary used to be invisible: adding a second
        // language silently changed what the Quality popup below meant.
        languagesCard.addRow(RowBuilder.row(
            label: modeTitle,
            sub: modeDetail,
            leadingSymbol: modeSymbol,
            leadingTint: Theme.text2,
            control: StatusBadgeView(kind: modeBadgeKind, label: modeBadgeLabel)))

        for w in setup.warnings where isCardLevel(w) {
            languagesCard.addRow(warningRow(w))
        }
        languagesCard.addRow(buildFooter(), last: true)

        if let sel = selectedCode, rows[sel] == nil { selectedCode = nil }
        if let sel = selectedCode { rows[sel]?.setHighlighted(true) }
    }

    /// Per-language problems are drawn on the language's own row; these two are
    /// about the setup as a whole and get their own line.
    private func isCardLevel(_ w: LanguageSetup.Warning) -> Bool {
        switch w {
        case .noDetectionModel, .vadMissing: return true
        case .modelMissing, .noModelForLanguage: return false
        }
    }

    private func warningRow(_ w: LanguageSetup.Warning) -> NSView {
        var control: NSView = StatusBadgeView(kind: .warn, label: "Needs attention")
        // Both card-level warnings are fixable by fetching one specific model,
        // so offer the fetch right there rather than sending the user to
        // another pane to work out which file it was.
        let fix: Model? = {
            switch w {
            case .noDetectionModel: return Models.largeV3
            case .vadMissing:       return Models.sileroVAD
            default:                return nil
            }
        }()
        if let fix {
            let target = ActionTarget { [weak self] in self?.downloadModel(fix.filename) }
            let b = StyledButton(title: "Download", target: target, action: #selector(ActionTarget.fire))
            b.kind = .primary
            objc_setAssociatedObject(b, &ActionTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
            control = b
        }
        return RowBuilder.row(label: warningTitle(w), sub: w.message,
                              leadingSymbol: "exclamationmark.triangle",
                              leadingTint: Theme.warn,
                              control: control)
    }

    private func warningTitle(_ w: LanguageSetup.Warning) -> String {
        switch w {
        case .noDetectionModel: return "Ghostie can't tell your languages apart"
        case .vadMissing:       return "Silence detection is missing"
        case .modelMissing:     return "Model not downloaded"
        case .noModelForLanguage: return "No model for this language"
        }
    }

    private var modeTitle: String {
        switch setup.mode {
        case .unconfigured:      return "Nothing to transcribe with yet"
        case .single(let l):     return "One language — \(WhisperLanguages.displayName(l))"
        case .codeSwitch(let l): return "\(l.count) languages, detected per speaker"
        }
    }

    private var modeDetail: String {
        switch setup.mode {
        case .unconfigured:
            return "Add a language above and Ghostie will fetch the model it needs."
        case .single(let l):
            return "Everything is transcribed as \(WhisperLanguages.displayName(l)). Add a second language and Ghostie starts detecting which one each speaker is using."
        case .codeSwitch:
            let driver = setup.detectionModelLabel ?? "—"
            return "Ghostie splits each track at the pauses, works out which language each stretch is, and sends it to that language's model. Detection runs on \(driver)."
        }
    }

    private var modeSymbol: String {
        switch setup.mode {
        case .unconfigured:  return "questionmark.circle"
        case .single:        return "text.bubble"
        case .codeSwitch:    return "arrow.triangle.branch"
        }
    }

    private var modeBadgeKind: StatusBadgeView.Kind {
        switch setup.mode {
        case .unconfigured: return .warn
        case .single:       return .ok
        case .codeSwitch:   return setup.detectionModelLabel == nil ? .warn : .ok
        }
    }

    private var modeBadgeLabel: String {
        switch setup.mode {
        case .unconfigured: return "Not ready"
        case .single:       return "Ready"
        case .codeSwitch:   return setup.detectionModelLabel == nil ? "Degraded" : "Ready"
        }
    }

    /// The `+ −` toolbar beneath the language list.
    private func buildFooter() -> NSView {
        let seg = NSSegmentedControl()
        seg.segmentStyle = .smallSquare
        seg.trackingMode = .momentary
        seg.segmentCount = 2
        seg.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Add a language"), forSegment: 0)
        seg.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove language"), forSegment: 1)
        seg.setWidth(34, forSegment: 0)
        seg.setWidth(34, forSegment: 1)
        // Removing the last language would leave nothing to transcribe with, so
        // the control is disabled and *says why* on hover — the old checkbox
        // silently snapped back instead.
        let canRemove = selectedCode != nil && setup.rows.count > 1
        seg.setEnabled(canRemove, forSegment: 1)
        seg.toolTip = setup.rows.count > 1
            ? "Remove the selected language"
            : "Ghostie needs at least one language"
        seg.translatesAutoresizingMaskIntoConstraints = false
        let target = ActionTarget { [weak self, weak seg] in
            guard let self, let seg else { return }
            if seg.selectedSegment == 0 { self.addLanguage() }
            else if let sel = self.selectedCode { self.removeLanguage(sel) }
        }
        seg.target = target
        seg.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(seg, &ActionTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        footerSeg = seg

        let hint = NSTextField(labelWithString:
            setup.isConfigured ? "" : "Following what's installed — adding or removing a language pins this list.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = Theme.text2
        hint.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(seg)
        container.addSubview(hint)
        NSLayoutConstraint.activate([
            seg.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            seg.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            seg.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            seg.heightAnchor.constraint(equalToConstant: 22),
            hint.leadingAnchor.constraint(equalTo: seg.trailingAnchor, constant: 12),
            hint.centerYAnchor.constraint(equalTo: seg.centerYAnchor),
            hint.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -14)
        ])
        return container
    }

    private func select(_ code: String) {
        selectedCode = code
        for (c, row) in rows { row.setHighlighted(c == code) }
        footerSeg?.setEnabled(setup.rows.count > 1, forSegment: 1)
    }

    /// The per-row `⋯` menu — everything you can do to one language, in one
    /// place, instead of split across two cards.
    private func showRowMenu(for r: LanguageSetup.Row, from view: NSView) {
        select(r.code)
        let menu = NSMenu()
        let target = MenuTarget { [weak self] item in
            guard let self else { return }
            switch item.representedObject as? String {
            case "model":   self.changeModel(r.code)
            case "primary": self.setPrimary(r.code)
            case "verify":  if let f = r.modelFilename { self.downloadModel(f) }
            case "remove":  self.removeLanguage(r.code)
            default:        break
            }
        }
        menuTarget = target
        func item(_ title: String, _ id: String, enabled: Bool = true) {
            let it = NSMenuItem(title: title, action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            it.representedObject = id
            it.target = target
            it.isEnabled = enabled
            menu.addItem(it)
        }
        item("Change model…", "model")
        item("Use as the fallback language", "primary", enabled: !r.isPrimary)
        if r.state == .missing { item("Download the model", "verify") }
        menu.addItem(.separator())
        item("Remove \(r.name)…", "remove", enabled: setup.rows.count > 1)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }

    // MARK: Quality card

    private func rebuildQuality() {
        qualityContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let quality = GroupCard(title: "Quality")
        qualityCard = quality

        // `transcriptionQuality` only picks a model on the single-language
        // path; with code-switching each language's own model decodes it. The
        // row used to sit there regardless, quietly doing nothing.
        if case .codeSwitch = setup.mode {} else {
            let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
            qualityPopup.addItems(withTitles: ["Best quality", "Balanced (lighter)"])
            qualityPopup.selectItem(at: cfg.transcriptionQuality == "balanced" ? 1 : 0)
            let qualityTarget = ToggleTarget { [weak self] in
                let next = (qualityPopup.indexOfSelectedItem == 1) ? "balanced" : "best"
                guard let self, self.cfg.transcriptionQuality != next else { return }
                self.change { c in c.transcriptionQuality = next }
                // The single-language model is resolved from disk at load, not
                // persisted, so re-read the effective pick.
                self.cfg.whisperModel = Config.load().whisperModel
                self.rebuild()
            }
            qualityPopup.target = qualityTarget
            qualityPopup.action = #selector(ToggleTarget.fire)
            objc_setAssociatedObject(qualityPopup, &ToggleTarget.key, qualityTarget, .OBJC_ASSOCIATION_RETAIN)
            qualityPopup.widthAnchor.constraint(equalToConstant: 180).isActive = true
            quality.addRow(RowBuilder.row(
                label: "Model for one-language calls",
                sub: "Balanced uses a smaller model — lighter on CPU, slightly less accurate.",
                control: qualityPopup))
        }

        quality.addRow(buildToggleRow(
            label: "Tidy up the transcript",
            sub: "Trims the things Whisper sometimes invents in silent stretches, like \"Thanks for watching.\"",
            on: cfg.cleanTranscript) { [weak self] on in
                self?.change { c in c.cleanTranscript = on }
            })
        let vadOnDisk = FileManager.default.fileExists(atPath: Models.sileroVAD.destPath)
        quality.addRow(RowBuilder.row(
            label: "Skip the quiet bits",
            sub: vadOnDisk ? "Ghostie uses the Silero model to find pauses and ignore them."
                           : "Download the Silero VAD model to turn this on.",
            control: StatusBadgeView(kind: vadOnDisk ? .ok : .muted,
                                     label: vadOnDisk ? "Active" : "Inactive")),
                       last: true)
        qualityContainer.addArrangedSubview(quality)
        quality.widthAnchor.constraint(equalTo: qualityContainer.widthAnchor).isActive = true

        // Speakers card. Telling your voice from theirs never needs a model —
        // that comes from recording the microphone and the call on separate
        // tracks. These two rows are about the far end: splitting it into
        // individual people, and giving those people names.
        let speakers = GroupCard(title: "Speakers")
        let spkOnDisk = FileManager.default.fileExists(
            atPath: cfg.speakerModel.isEmpty ? SpeakerEmbedder.defaultModelPath
                                             : cfg.speakerModel)
        let ortOnDisk = ORTRuntime.shared != nil
        let canDiarize = spkOnDisk && ortOnDisk
        speakers.addRow(buildToggleRow(
            label: "Tell participants apart",
            sub: canDiarize
                ? "When several people share the other end of the call, label each of them separately instead of lumping them together."
                : (spkOnDisk
                   ? "Needs the ONNX Runtime — install it with `brew install onnxruntime`, or reinstall Ghostie from a build that includes it."
                   : "Downloading the speaker model (~27 MB). Until it arrives, everyone on the other end shares one label."),
            on: cfg.diarization && canDiarize) { [weak self] on in
                self?.change { c in c.diarization = on }
            })
        speakers.addRow(buildToggleRow(
            label: "Use people's names",
            sub: "Reads names off the conversation — greetings, introductions, who gets addressed — and uses them in the transcript instead of \"Me\" and \"Participant 1\". Falls back to the plain labels when a name isn't clear.",
            on: cfg.nameSpeakers) { [weak self] on in
                self?.change { c in c.nameSpeakers = on }
            }, last: true)
        qualityContainer.addArrangedSubview(speakers)
        speakers.widthAnchor.constraint(equalTo: qualityContainer.widthAnchor).isActive = true
    }

    // MARK: Advanced disclosure

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

        // One editable starter sentence per language, writing that language's
        // own record. Enumerating `setup.rows` (not a separate lookup) means
        // this list can't disagree with the list above it.
        for r in setup.rows {
            let field = NSTextField(string: cfg.codeSwitch.prompt(for: r.code))
            field.placeholderString = "Optional — terms and style for \(r.name)"
            field.font = .systemFont(ofSize: 12)
            field.lineBreakMode = .byTruncatingTail
            field.cell?.sendsActionOnEndEditing = true
            field.widthAnchor.constraint(equalToConstant: 260).isActive = true
            let target = ToggleTarget { [weak self, weak field] in
                guard let self, let field else { return }
                let v = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                self.change { c in
                    var langs = LanguageSetup.materialized(config: c)
                    guard let i = langs.firstIndex(where: { $0.code == r.code }) else { return }
                    // "" is a real choice (no prompt at all); the built-in
                    // default only applies while the field was never touched,
                    // so an emptied field that matches the default clears back
                    // to nil rather than pinning an empty string forever.
                    langs[i].prompt = v.isEmpty && LanguageDefaults.prompt(for: r.code).isEmpty
                        ? nil : v
                    c.codeSwitch.languages = langs
                }
            }
            field.target = target
            field.action = #selector(ToggleTarget.fire)
            objc_setAssociatedObject(field, &ToggleTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
            card.addRow(RowBuilder.row(
                label: "Starter sentence (\(r.name))",
                sub: "Biases punctuation and vocabulary when decoding \(r.name) segments.",
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

    // MARK: Download progress
    //
    // Routed by model filename (the download key) to whichever language row is
    // showing that model. A model no language uses — VAD, or one being fetched
    // from the Developer pane — simply matches nothing here.

    func setDownloading(modelFilename key: String, percent: Double, status: String) {
        for r in setup.rows where r.modelFilename == key {
            rows[r.code]?.setDownloading(percent: percent, status: status)
        }
    }

    func setBusy(modelFilename key: String, status: String) {
        for r in setup.rows where r.modelFilename == key {
            rows[r.code]?.setBusy(status: status)
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

// MARK: - Language row

/// One language: what it is, which model serves it, whether that model is
/// ready, and a `⋯` for everything you can do to it. The model is stated in
/// words on the row rather than implied by a tickmark in a separate list.
private final class LanguageRowView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let badge: StatusBadgeView
    private let menuButton = StyledButton(title: "⋯", target: nil, action: nil)
    private let actionButton: StyledButton?
    private let progressBar = ProgressBar()
    private let statusLine = NSTextField(labelWithString: "")
    private var progressHeight: NSLayoutConstraint!
    private var statusHeight: NSLayoutConstraint!
    private var subtitleToBottom: NSLayoutConstraint!
    private var statusToBottom: NSLayoutConstraint!

    var onSelect: (() -> Void)?
    var onMenu: ((NSView) -> Void)?
    var onAction: (() -> Void)?

    init(row r: LanguageSetup.Row) {
        switch r.state {
        case .onDisk:
            badge = StatusBadgeView(kind: .ok, label: "Ready")
            actionButton = nil
        case .missing:
            badge = StatusBadgeView(kind: .muted, label: "Not downloaded")
            actionButton = StyledButton(title: "Download", target: nil, action: nil)
        case .none:
            badge = StatusBadgeView(kind: .warn, label: "No model")
            actionButton = StyledButton(title: "Pick model…", target: nil, action: nil)
        }
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)

        title.stringValue = WhisperLanguages.label(r.code)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = Theme.text
        title.translatesAutoresizingMaskIntoConstraints = false
        title.setContentHuggingPriority(.required, for: .horizontal)

        subtitle.stringValue = Self.describe(r)
        subtitle.font = .systemFont(ofSize: 11.5)
        subtitle.textColor = Theme.text2
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        statusLine.font = .systemFont(ofSize: 11)
        statusLine.textColor = Theme.text2
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        statusLine.isHidden = true

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true

        badge.translatesAutoresizingMaskIntoConstraints = false

        menuButton.kind = .ghost
        menuButton.widthAnchor.constraint(equalToConstant: 32).isActive = true
        let menuTarget = ActionTarget { [weak self] in
            guard let self else { return }
            self.onMenu?(self.menuButton)
        }
        menuButton.target = menuTarget
        menuButton.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(menuButton, &ActionTarget.key, menuTarget, .OBJC_ASSOCIATION_RETAIN)

        addSubview(title)
        addSubview(subtitle)
        addSubview(badge)
        addSubview(menuButton)
        addSubview(progressBar)
        addSubview(statusLine)

        // The trailing control column runs right-to-left: ⋯, then the action
        // button when there is one, then the badge.
        var rightAnchorView: NSView = menuButton
        if let actionButton {
            actionButton.kind = .primary
            actionButton.translatesAutoresizingMaskIntoConstraints = false
            actionButton.widthAnchor.constraint(equalToConstant: 110).isActive = true
            let t = ActionTarget { [weak self] in self?.onAction?() }
            actionButton.target = t
            actionButton.action = #selector(ActionTarget.fire)
            objc_setAssociatedObject(actionButton, &ActionTarget.key, t, .OBJC_ASSOCIATION_RETAIN)
            addSubview(actionButton)
            NSLayoutConstraint.activate([
                actionButton.trailingAnchor.constraint(equalTo: menuButton.leadingAnchor, constant: -8),
                actionButton.centerYAnchor.constraint(equalTo: title.centerYAnchor)
            ])
            rightAnchorView = actionButton
        }

        progressHeight = progressBar.heightAnchor.constraint(equalToConstant: 0)
        statusHeight = statusLine.heightAnchor.constraint(equalToConstant: 0)
        progressHeight.isActive = true
        statusHeight.isActive = true

        subtitleToBottom = bottomAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 11)
        statusToBottom = bottomAnchor.constraint(equalTo: statusLine.bottomAnchor, constant: 9)
        subtitleToBottom.isActive = true

        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),

            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 2),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),

            badge.trailingAnchor.constraint(equalTo: rightAnchorView.leadingAnchor, constant: -12),
            badge.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            menuButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            menuButton.centerYAnchor.constraint(equalTo: title.centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progressBar.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 8),

            statusLine.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            statusLine.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 3),
            statusLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The row's one-line story: which model, how big, and any role it plays.
    /// These roles (detection driver, fallback language) were previously
    /// invisible — the detection driver in particular decides routing quality
    /// for every other language and was never surfaced anywhere but `doctor`.
    private static func describe(_ r: LanguageSetup.Row) -> String {
        guard let label = r.modelLabel else {
            return "No model yet — pick one and Ghostie will download it."
        }
        var parts = [label]
        if r.modelIsExplicit { parts.append("pinned") }
        if r.drivesDetection { parts.append("also tells your languages apart") }
        if r.isPrimary { parts.append("fallback when detection is unsure") }
        return parts.joined(separator: " · ")
    }

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

    func setDownloading(percent: Double, status: String) {
        badge.set(kind: .info, label: "Downloading")
        setProgressVisible(true)
        progressBar.set(progress: percent)
        statusLine.stringValue = status
    }

    func setBusy(status: String) {
        setProgressVisible(true)
        progressBar.set(progress: 0)
        statusLine.stringValue = status
    }
}
