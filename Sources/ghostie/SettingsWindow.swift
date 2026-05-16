import AppKit

/// A real Settings window (no more "open the JSON"). Edits the on-disk config,
/// saves it, and applies the change to the running engine immediately.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onSave: (Config) -> Void
    var onClose: (() -> Void)?

    // Controls we read back on Save.
    private let notesField = NSTextField()
    private let keepAudio = NSButton(checkboxWithTitle: "Keep raw audio recordings after processing", target: nil, action: nil)
    private let saveTranscript = NSButton(checkboxWithTitle: "Save a separate transcript file alongside the summary", target: nil, action: nil)
    private let requireTeams = NSButton(checkboxWithTitle: "Only treat microphone use as a call when Microsoft Teams is running", target: nil, action: nil)
    private let endGrace = NSTextField()
    private let minCall = NSTextField()
    private let whisperModelField = NSTextField()
    private let languageBox = NSComboBox()
    private let cleanTranscript = NSButton(checkboxWithTitle: "Clean transcript (remove whisper hallucinations)", target: nil, action: nil)
    private let promptView = NSTextView()
    private let vadField = NSTextField()
    private let claudeField = NSTextField()
    private let summaryBox = NSComboBox()

    init(onSave: @escaping (Config) -> Void) {
        self.onSave = onSave
        super.init()
    }

    // MARK: Presentation

    func show() {
        if let window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let cfg = Config.loadRaw()
        let content = buildForm(cfg)

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 430),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Ghostie Settings"
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = content
        win.center()

        self.window = win
        NSApp.activate(ignoringOtherApps: true)
        win.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        onClose?()
    }

    // MARK: Form

    private func buildForm(_ cfg: Config) -> NSView {
        notesField.stringValue = cfg.notesFolder
        keepAudio.state = cfg.keepAudio ? .on : .off
        saveTranscript.state = cfg.saveTranscript ? .on : .off
        requireTeams.state = cfg.requireTriggerApp ? .on : .off
        endGrace.stringValue = String(Int(cfg.endGraceSeconds))
        minCall.stringValue = String(Int(cfg.minCallSeconds))
        whisperModelField.stringValue = cfg.whisperModel
        cleanTranscript.state = cfg.cleanTranscript ? .on : .off
        vadField.stringValue = cfg.vadModel

        languageBox.addItems(withObjectValues: ["en", "auto", "sv", "de", "fr", "es", "it", "nl", "pt"])
        languageBox.stringValue = cfg.language
        languageBox.completes = true

        summaryBox.addItems(withObjectValues: ["claude-sonnet-4-6", "claude-opus-4-7", "claude-haiku-4-5-20251001"])
        summaryBox.stringValue = cfg.summaryModel
        summaryBox.completes = true

        claudeField.stringValue = cfg.claudeBinary.isEmpty
            ? Config.findClaudeBinary() : cfg.claudeBinary
        claudeField.placeholderString = "auto-detected"

        for f in [notesField, endGrace, minCall, whisperModelField, vadField, claudeField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.controlSize = .regular
            f.usesSingleLineMode = true
            f.alignment = .left
            f.lineBreakMode = .byTruncatingTail
            f.cell?.wraps = false
            f.cell?.isScrollable = true
            f.cell?.alignment = .left
        }
        // Long paths start flush-left like every other control; the truncated
        // tail is shown with the full path available on hover.
        for f in [notesField, whisperModelField, vadField, claudeField] {
            f.toolTip = f.stringValue
        }
        endGrace.alignment = .right
        minCall.alignment = .right

        // ---- Tabs --------------------------------------------------------
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab("General", [
            row("Notes folder", pathPicker(notesField, chooseDir: true)),
            keepAudio,
            saveTranscript,
            caption("Summaries are written here as markdown after each call.")
        ]))
        tabs.addTabViewItem(tab("Detection", [
            requireTeams,
            row("End call after mic idle", suffixed(endGrace, "seconds", width: 70)),
            row("Ignore calls shorter than", suffixed(minCall, "seconds", width: 70)),
            caption("A call is detected from microphone use; it ends after the mic is idle for the grace period.")
        ]))
        tabs.addTabViewItem(tab("Transcription", [
            row("Whisper model", pathPicker(whisperModelField, chooseDir: false)),
            row("Language", sized(languageBox, 120)),
            cleanTranscript,
            label("Initial prompt (biases whisper toward clean, punctuated speech)"),
            promptBox(cfg.initialPrompt),
            row("Silero VAD model", pathPicker(vadField, chooseDir: false)),
            caption("VAD is optional. Run  ./scripts/setup.sh --vad  to fetch it; Ghostie auto-uses it when present.")
        ]))
        tabs.addTabViewItem(tab("Summary", [
            row("Claude CLI", pathPicker(claudeField, chooseDir: false)),
            caption("Summaries use the Claude Code CLI (`claude -p`) with your existing login — no API key needed. Run `claude` once in a terminal to sign in. Only the text transcript is sent; audio never leaves your Mac."),
            row("Model", sized(summaryBox, 260))
        ]))

        // ---- Buttons -----------------------------------------------------
        let openJSON = NSButton(title: "Open config.json", target: self, action: #selector(openJSON))
        openJSON.bezelStyle = .rounded
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        let save = NSButton(title: "Save", target: self, action: #selector(saveAndClose))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [openJSON, spacer, cancel, save])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let header = caption("Audio and transcription always stay 100% local. Changes apply to your next call immediately.")
        header.translatesAutoresizingMaskIntoConstraints = false
        let sep = separatorLine()
        sep.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(header)
        root.addSubview(tabs)
        root.addSubview(sep)
        root.addSubview(buttons)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),

            tabs.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            tabs.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            tabs.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            sep.topAnchor.constraint(equalTo: tabs.bottomAnchor, constant: 12),
            sep.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            sep.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            buttons.topAnchor.constraint(equalTo: sep.bottomAnchor, constant: 12),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 18),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        return root
    }

    /// One tab: a top-aligned vertical stack of rows inside a container.
    private func tab(_ label: String, _ rows: [NSView]) -> NSTabViewItem {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        rows.forEach { stack.addArrangedSubview($0) }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor, constant: -18)
        ])
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = container
        return item
    }

    // MARK: Builders

    private func label(_ s: String) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = .systemFont(ofSize: 12)
        return t
    }
    private func caption(_ s: String) -> NSTextField {
        let t = NSTextField(wrappingLabelWithString: s)
        t.font = .systemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        return t
    }
    private func separatorLine() -> NSView {
        let v = NSBox(); v.boxType = .separator
        return v
    }
    private func row(_ labelText: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: labelText)
        l.alignment = .right
        l.font = .systemFont(ofSize: 12)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: 165).isActive = true
        l.setContentHuggingPriority(.required, for: .horizontal)
        let h = NSStackView(views: [l, control])
        h.orientation = .horizontal
        h.spacing = 10
        h.alignment = .firstBaseline
        return h
    }
    private func sized(_ v: NSView, _ w: CGFloat) -> NSView {
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        return v
    }
    private func suffixed(_ field: NSTextField, _ suffix: String, width: CGFloat) -> NSView {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        let s = NSTextField(labelWithString: suffix)
        s.font = .systemFont(ofSize: 12)
        s.textColor = .secondaryLabelColor
        let h = NSStackView(views: [field, s])
        h.orientation = .horizontal
        h.spacing = 6
        h.alignment = .firstBaseline
        return h
    }
    private func pathPicker(_ field: NSTextField, chooseDir: Bool) -> NSView {
        field.widthAnchor.constraint(greaterThanOrEqualToConstant: 280).isActive = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let btn = NSButton(title: "Choose…",
                           target: self,
                           action: chooseDir ? #selector(chooseFolder(_:)) : #selector(chooseFile(_:)))
        btn.bezelStyle = .rounded
        btn.tag = chooseDir ? 1 : 2
        btn.setContentHuggingPriority(.required, for: .horizontal)
        objc_setAssociatedObject(btn, &Self.fieldKey, field, .OBJC_ASSOCIATION_RETAIN)
        let h = NSStackView(views: [field, btn])
        h.orientation = .horizontal
        h.spacing = 8
        h.distribution = .fill   // field stretches, button keeps its size
        return h
    }
    private static var fieldKey: UInt8 = 0
    private func promptBox(_ text: String) -> NSView {
        promptView.string = text
        promptView.font = .systemFont(ofSize: 12)
        promptView.isRichText = false
        promptView.textContainerInset = NSSize(width: 4, height: 6)
        let sc = NSScrollView()
        sc.borderType = .bezelBorder
        sc.hasVerticalScroller = true
        sc.documentView = promptView
        sc.translatesAutoresizingMaskIntoConstraints = false
        sc.heightAnchor.constraint(equalToConstant: 64).isActive = true
        sc.widthAnchor.constraint(greaterThanOrEqualToConstant: 480).isActive = true
        return sc
    }

    // MARK: Actions

    @objc private func chooseFolder(_ sender: NSButton) { pick(sender, directories: true) }
    @objc private func chooseFile(_ sender: NSButton) { pick(sender, directories: false) }

    private func pick(_ sender: NSButton, directories: Bool) {
        guard let field = objc_getAssociatedObject(sender, &Self.fieldKey) as? NSTextField
        else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = directories
        panel.canChooseFiles = !directories
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        if !field.stringValue.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: field.stringValue)
                .deletingLastPathComponent()
        }
        if panel.runModal() == .OK, let url = panel.url {
            field.stringValue = url.path
        }
    }

    @objc private func openJSON() {
        let url = URL(fileURLWithPath: Config.configPath)
        if !FileManager.default.fileExists(atPath: url.path) {
            Config.loadRaw().save()
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func cancel() { window?.close() }

    @objc private func saveAndClose() {
        var cfg = Config.loadRaw()   // preserve advanced fields not in the form
        cfg.notesFolder = notesField.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.keepAudio = keepAudio.state == .on
        cfg.saveTranscript = saveTranscript.state == .on
        cfg.requireTriggerApp = requireTeams.state == .on
        cfg.endGraceSeconds = Double(endGrace.stringValue) ?? cfg.endGraceSeconds
        cfg.minCallSeconds = Double(minCall.stringValue) ?? cfg.minCallSeconds
        cfg.whisperModel = whisperModelField.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.language = languageBox.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.cleanTranscript = cleanTranscript.state == .on
        cfg.initialPrompt = promptView.string
        cfg.vadModel = vadField.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.summaryModel = summaryBox.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.claudeBinary = claudeField.stringValue.trimmingCharacters(in: .whitespaces)

        if cfg.save() {
            onSave(Config.load())
        }
        window?.close()
    }
}
