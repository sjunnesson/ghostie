import AppKit

// MARK: - Pane: Summary

final class SummaryPane: NSView {
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
        // Rows come from `ClaudeModels`, which offers *tier aliases* rather than
        // pinned version ids — an alias resolves to whatever is current, so this
        // picker doesn't fall behind Anthropic's releases the way the old
        // hardcoded version list did. Whatever is configured is always one of
        // the rows, so the picker can't display one model while another is set.
        let (entries, selected) = ClaudeModels.menu(configured: cfgState.summaryModel)
        let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for entry in entries {
            modelPopup.addItem(withTitle: ClaudeModels.title(for: entry))
        }
        modelPopup.selectItem(at: selected)
        let modelTarget = ToggleTarget { [weak self] in
            guard let self else { return }
            let i = modelPopup.indexOfSelectedItem
            guard i >= 0, i < entries.count else { return }
            switch entries[i] {
            case .alias(let id), .pinned(let id):
                self.applySummaryModel(id)
            case .custom:
                // Restore the selection first: if the prompt is cancelled the
                // picker must go back to showing what's actually configured.
                modelPopup.selectItem(at: selected)
                if let id = self.promptForModelID() { self.applySummaryModel(id) }
            }
        }
        modelPopup.target = modelTarget
        modelPopup.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(modelPopup, &ToggleTarget.key, modelTarget, .OBJC_ASSOCIATION_RETAIN)
        modelPopup.widthAnchor.constraint(equalToConstant: 220).isActive = true
        card.addRow(RowBuilder.row(
            label: "Which Claude writes the note",
            sub: ClaudeModels.summary(for: cfgState.summaryModel),
            control: modelPopup), last: true)
    }

    private func applySummaryModel(_ id: String) {
        guard id != cfgState.summaryModel else { return }
        cfgState.summaryModel = id
        changes { c in c.summaryModel = id }
        // The sentence under the picker describes the selection, and a pinned
        // id adds a row — so redraw the card rather than leaving stale copy.
        refreshProviderCard()
    }

    /// Prompt for an exact model id, for pinning a specific version (or
    /// reaching a model with no tier alias). Deliberately not validated against
    /// a list — a list is what went stale in the first place; a wrong id
    /// surfaces as a clear failure from `claude -p` on the next call.
    private func promptForModelID() -> String? {
        let field = NSTextField(string: ClaudeModels.isAlias(cfgState.summaryModel)
                                ? "" : cfgState.summaryModel)
        field.placeholderString = "claude-sonnet-5"
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: 320).isActive = true
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        container.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: container.topAnchor),
            field.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            field.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        let a = NSAlert()
        a.messageText = "Use a specific model version"
        a.informativeText = "Type the exact model name, like claude-sonnet-5. Pinning a version means Ghostie stops following newer models — and stops working if that one is retired. The tier options above avoid both."
        a.accessoryView = container
        a.addButton(withTitle: "Use it")
        a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard a.runModal() == .alertFirstButtonReturn else { return nil }
        let id = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
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
