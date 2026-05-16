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
    private let apiKeyField = NSSecureTextField()
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

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = content
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 660),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false)
        win.title = "Ghostie Settings"
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.contentView = scroll
        win.center()

        // Document view fills the scroll view's width, grows vertically.
        if let doc = scroll.documentView {
            NSLayoutConstraint.activate([
                doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
                doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
                doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
                doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
            ])
        }
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

        apiKeyField.stringValue = cfg.anthropicApiKey
        apiKeyField.placeholderString = "sk-ant-…"

        for f in [notesField, endGrace, minCall, whisperModelField, vadField] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.controlSize = .regular
        }
        endGrace.alignment = .right
        minCall.alignment = .right

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(title("Ghostie Settings", size: 17, bold: true))
        stack.addArrangedSubview(caption("Audio and transcription always stay 100% local. Changes apply to your next call immediately."))

        stack.addArrangedSubview(section("General"))
        stack.addArrangedSubview(row("Notes folder", pathPicker(notesField, chooseDir: true)))
        stack.addArrangedSubview(keepAudio)
        stack.addArrangedSubview(saveTranscript)

        stack.addArrangedSubview(section("Detection"))
        stack.addArrangedSubview(requireTeams)
        stack.addArrangedSubview(row("End call after mic idle", suffixed(endGrace, "seconds", width: 70)))
        stack.addArrangedSubview(row("Ignore calls shorter than", suffixed(minCall, "seconds", width: 70)))

        stack.addArrangedSubview(section("Transcription"))
        stack.addArrangedSubview(row("Whisper model", pathPicker(whisperModelField, chooseDir: false)))
        stack.addArrangedSubview(row("Language", sized(languageBox, 120)))
        stack.addArrangedSubview(cleanTranscript)
        stack.addArrangedSubview(label("Initial prompt (biases whisper toward clean, punctuated speech)"))
        stack.addArrangedSubview(promptBox(cfg.initialPrompt))
        stack.addArrangedSubview(row("Silero VAD model", pathPicker(vadField, chooseDir: false)))
        stack.addArrangedSubview(caption("Optional. Run  ./scripts/setup.sh --vad  to fetch it; Ghostie auto-uses it when present."))

        stack.addArrangedSubview(section("Summary (Anthropic)"))
        stack.addArrangedSubview(row("API key", sized(apiKeyField, 320)))
        stack.addArrangedSubview(caption("Only the text transcript is sent to Anthropic, and only if a key is set."))
        stack.addArrangedSubview(row("Model", sized(summaryBox, 240)))

        // Buttons
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
        let bar = NSView()
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: bar.topAnchor, constant: 8),
            buttons.bottomAnchor.constraint(equalTo: bar.bottomAnchor)
        ])
        stack.addArrangedSubview(separatorLine())
        stack.addArrangedSubview(bar)

        // Make full-width arranged subviews actually span the stack width.
        let doc = NSView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor),
            stack.topAnchor.constraint(equalTo: doc.topAnchor),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor)
        ])
        for v in [bar, buttons] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                     constant: -44).isActive = true
        }
        return doc
    }

    // MARK: Builders

    private func title(_ s: String, size: CGFloat, bold: Bool) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = bold ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
        return t
    }
    private func section(_ s: String) -> NSView {
        let t = NSTextField(labelWithString: s.uppercased())
        t.font = .boldSystemFont(ofSize: 11)
        t.textColor = .secondaryLabelColor
        let box = NSStackView(views: [t])
        box.orientation = .vertical
        box.edgeInsets = NSEdgeInsets(top: 12, left: 0, bottom: 2, right: 0)
        return box
    }
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
        let btn = NSButton(title: "Choose…",
                           target: self,
                           action: chooseDir ? #selector(chooseFolder(_:)) : #selector(chooseFile(_:)))
        btn.bezelStyle = .rounded
        btn.tag = chooseDir ? 1 : 2
        objc_setAssociatedObject(btn, &Self.fieldKey, field, .OBJC_ASSOCIATION_RETAIN)
        let h = NSStackView(views: [field, btn])
        h.orientation = .horizontal
        h.spacing = 8
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
        cfg.anthropicApiKey = apiKeyField.stringValue.trimmingCharacters(in: .whitespaces)

        if cfg.save() {
            // Make the key live this session without a restart.
            runtimeConfigOverrideKey = cfg.anthropicApiKey
            onSave(Config.load())
        }
        window?.close()
    }
}
