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
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 540),
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
            field("Notes folder", pathControl(notesField, chooseDir: true)),
            keepAudio,
            saveTranscript,
            caption("Summaries are written here as markdown after each call.")
        ]))
        tabs.addTabViewItem(tab("Detection", [
            requireTeams,
            field("End call after mic idle", leftWrap(suffixed(endGrace, "seconds", width: 70))),
            field("Ignore calls shorter than", leftWrap(suffixed(minCall, "seconds", width: 70))),
            caption("A call is detected from microphone use; it ends after the mic is idle for the grace period.")
        ]))
        tabs.addTabViewItem(tab("Transcription", [
            field("Whisper model", pathControl(whisperModelField, chooseDir: false)),
            field("Language", leftWrap(sized(languageBox, 120))),
            cleanTranscript,
            field("Initial prompt (biases whisper toward clean, punctuated speech)",
                  promptBox(cfg.initialPrompt)),
            field("Silero VAD model", pathControl(vadField, chooseDir: false)),
            caption("VAD is optional. Run  ./scripts/setup.sh --vad  to fetch it; Ghostie auto-uses it when present.")
        ]))
        tabs.addTabViewItem(tab("Summary", [
            field("Claude CLI", pathControl(claudeField, chooseDir: false)),
            caption("Summaries use the Claude Code CLI (`claude -p`) with your existing login — no API key needed. Run `claude` once in a terminal to sign in. Only the text transcript is sent; audio never leaves your Mac."),
            field("Model", leftWrap(sized(summaryBox, 260)))
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
        rows.forEach {
            stack.addArrangedSubview($0)
            // Every row spans the full content width so fields can stretch.
            $0.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
            $0.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        }

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

    /// A label on its own line above a full-width control.
    private func field(_ labelText: String, _ control: NSView) -> NSView {
        let l = NSTextField(labelWithString: labelText)
        l.alignment = .left
        l.font = .systemFont(ofSize: 12)
        l.lineBreakMode = .byTruncatingTail
        l.translatesAutoresizingMaskIntoConstraints = false
        control.translatesAutoresizingMaskIntoConstraints = false

        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(l)
        v.addSubview(control)
        NSLayoutConstraint.activate([
            l.topAnchor.constraint(equalTo: v.topAnchor),
            l.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            l.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            control.topAnchor.constraint(equalTo: l.bottomAnchor, constant: 5),
            control.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            control.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        ])
        return v
    }

    /// Wrap a fixed-size control so it sits left-aligned inside a full-width
    /// row without being stretched (combos, numeric fields).
    private func leftWrap(_ inner: NSView) -> NSView {
        inner.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            inner.topAnchor.constraint(equalTo: v.topAnchor),
            inner.bottomAnchor.constraint(equalTo: v.bottomAnchor),
            inner.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor)
        ])
        return v
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
    /// A full-width text field that stretches up to a trailing "Choose…"
    /// button (no label — `field(_:_:)` supplies the label above it).
    private func pathControl(_ textField: NSTextField, chooseDir: Bool) -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let btn = NSButton(title: "Choose…",
                           target: self,
                           action: chooseDir ? #selector(chooseFolder(_:)) : #selector(chooseFile(_:)))
        btn.bezelStyle = .rounded
        btn.translatesAutoresizingMaskIntoConstraints = false
        btn.setContentHuggingPriority(.required, for: .horizontal)
        btn.setContentCompressionResistancePriority(.required, for: .horizontal)
        objc_setAssociatedObject(btn, &Self.fieldKey, textField, .OBJC_ASSOCIATION_RETAIN)

        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        container.addSubview(textField)
        container.addSubview(btn)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            textField.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -8),
            textField.topAnchor.constraint(equalTo: container.topAnchor),
            textField.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            btn.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            btn.centerYAnchor.constraint(equalTo: textField.centerYAnchor)
        ])
        return container
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
