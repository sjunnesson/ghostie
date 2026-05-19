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

    // Code-switching (sv ↔ en).
    private let csEnable = NSButton(checkboxWithTitle: "Enable code-switching (Swedish ↔ English, dual model)", target: nil, action: nil)
    private let csLanguages = NSTextField()
    private let csDominant = NSComboBox()
    private let csSvModel = NSTextField()
    private let csEnModel = NSTextField()
    private let csVariant = NSComboBox()
    private let csPromptSv = NSTextField()
    private let csPromptEn = NSTextField()
    private let csPriorStrength = NSTextField()
    private let csMinSwitch = NSTextField()
    private let csWindowMe = NSTextField()
    private let csWindowPart = NSTextField()
    private let csDownloadBtn = NSButton(title: "Download models (~2 GB)…",
                                         target: nil, action: nil)
    private let csDownloadStatus = NSTextField(wrappingLabelWithString: "")
    private let downloader = ModelDownloader()

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
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 600),
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
        downloader.cancel()
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

        // ---- Code-switching ---------------------------------------------
        let csc = cfg.codeSwitch
        csEnable.state = csc.enabled ? .on : .off
        csLanguages.stringValue = csc.languages.joined(separator: ", ")
        csDominant.addItems(withObjectValues: ["en", "sv"])
        csDominant.stringValue = csc.dominantLanguage
        csDominant.completes = true
        csSvModel.stringValue = csc.modelPerLanguage["sv"] ?? "kb-whisper-large"
        csEnModel.stringValue = csc.modelPerLanguage["en"] ?? "whisper-large-v3"
        csVariant.addItems(withObjectValues: ["standard", "subtitle", "strict"])
        csVariant.stringValue = csc.kbWhisperVariant
        csVariant.completes = true
        csPromptSv.stringValue = csc.promptSv
        csPromptEn.stringValue = csc.promptEn
        csPriorStrength.stringValue = String(csc.crossTrackPriorStrength)
        csMinSwitch.stringValue = String(csc.minSwitchSegments)
        csWindowMe.stringValue = String(csc.smoothingWindowMe)
        csWindowPart.stringValue = String(csc.smoothingWindowParticipants)

        for f in [notesField, endGrace, minCall, whisperModelField, vadField, claudeField,
                  csLanguages, csSvModel, csEnModel, csPromptSv, csPromptEn,
                  csPriorStrength, csMinSwitch, csWindowMe, csWindowPart] {
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
        for f in [notesField, whisperModelField, vadField, claudeField,
                  csSvModel, csEnModel] {
            f.toolTip = f.stringValue
        }
        endGrace.alignment = .right
        minCall.alignment = .right
        for f in [csPriorStrength, csMinSwitch, csWindowMe, csWindowPart] {
            f.alignment = .right
        }

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
        csDownloadStatus.font = .systemFont(ofSize: 11)
        csDownloadStatus.textColor = .secondaryLabelColor
        csDownloadBtn.bezelStyle = .rounded
        csDownloadBtn.target = self
        csDownloadBtn.action = #selector(downloadModels)

        // One tab. Single-language and code-switching are mutually exclusive
        // (code-switching replaces the single-language pass when enabled), so
        // they live together under clearly grouped headers; the two settings
        // that apply to *both* modes are pulled out on top so they aren't
        // hidden from code-switching users.
        tabs.addTabViewItem(tab("Transcription", [
            section("Applies to every transcription"),
            cleanTranscript,
            field("Silero VAD model", pathControl(vadField, chooseDir: false)),
            caption("Required for code-switching; recommended otherwise (biggest reducer of silence hallucinations). ./scripts/setup.sh --vad fetches it."),

            section("Single-language mode"),
            caption("Used when code-switching (below) is OFF — one model for the whole call."),
            field("Whisper model", pathControl(whisperModelField, chooseDir: false)),
            field("Language", leftWrap(sized(languageBox, 120))),
            field("Initial prompt (biases whisper toward clean, punctuated speech)",
                  promptBox(cfg.initialPrompt)),

            section("Code-switching (Swedish ↔ English)"),
            csEnable,
            caption("When ON this REPLACES single-language mode: each speech run is decoded by the best model for its language — KB-Whisper for Swedish, whisper-large-v3 for English. The model/language/prompt above are then unused."),
            field("Languages (comma-separated; first two are used)",
                  leftWrap(sized(csLanguages, 160))),
            field("Dominant language (tiebreaker)", leftWrap(sized(csDominant, 120))),
            field("Swedish model", pathControl(csSvModel, chooseDir: false)),
            field("English model", pathControl(csEnModel, chooseDir: false)),
            caption("A known name (kb-whisper-large, whisper-large-v3) resolves under ~/.ghostie/models/, or Choose… a specific .bin file."),
            field("Swedish transcription style", leftWrap(sized(csVariant, 160))),
            caption("standard = balanced (best for notes) · subtitle = condensed · strict = verbatim, keeps filler. (‘subtitle’ has no downloadable model — use standard or strict.)"),
            leftWrap(csDownloadBtn),
            csDownloadStatus,
            caption("Downloads the chosen Swedish model + whisper-large-v3 + VAD into ~/.ghostie/models/ (≈2 GB; skips files already there). Or run  ./scripts/setup.sh --codeswitch."),
            field("Swedish prompt", csPromptSv),
            field("English prompt", csPromptEn),
            field("Cross-track prior strength (0.5 disables · 1.0 absolute)",
                  leftWrap(sized(csPriorStrength, 70))),
            field("Min consecutive segments to switch language",
                  leftWrap(sized(csMinSwitch, 70))),
            field("Smoothing window — Me / Participants",
                  leftWrap(pair(csWindowMe, csWindowPart))),
            caption("Other advanced knobs (fill gap, run/silence padding, min detect ms, prior lookback) are in config.json.")
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

    /// One tab: a top-aligned vertical stack of rows, vertically scrollable so
    /// a long tab (the combined Transcription tab) never clips.
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

        // Flipped doc view → content starts at the top and scrolls down.
        let doc = FlippedView()
        doc.translatesAutoresizingMaskIntoConstraints = false
        doc.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: doc.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: doc.leadingAnchor, constant: 22),
            stack.trailingAnchor.constraint(equalTo: doc.trailingAnchor, constant: -22),
            stack.bottomAnchor.constraint(equalTo: doc.bottomAnchor, constant: -18)
        ])

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.documentView = doc
        // Match doc width to the viewport so it only scrolls vertically and
        // full-width fields still stretch.
        NSLayoutConstraint.activate([
            doc.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            doc.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            doc.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            doc.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)
        ])

        let container = NSView()
        container.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: container.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = container
        return item
    }

    /// Bold group header inside a tab.
    private func section(_ s: String) -> NSView {
        let t = NSTextField(labelWithString: s.uppercased())
        t.font = .systemFont(ofSize: 11, weight: .semibold)
        t.textColor = .secondaryLabelColor
        return t
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
    /// Two small numeric fields side by side with a "/" between them.
    private func pair(_ a: NSTextField, _ b: NSTextField) -> NSView {
        for f in [a, b] {
            f.translatesAutoresizingMaskIntoConstraints = false
            f.widthAnchor.constraint(equalToConstant: 60).isActive = true
        }
        let slash = NSTextField(labelWithString: "/")
        slash.textColor = .secondaryLabelColor
        let h = NSStackView(views: [a, slash, b])
        h.orientation = .horizontal
        h.spacing = 8
        h.alignment = .firstBaseline
        return h
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

    @objc private func downloadModels() {
        if downloader.isRunning { return }
        let variant = csVariant.stringValue.trimmingCharacters(in: .whitespaces)
        guard let items = ModelDownloader.items(variant: variant) else {
            alert(.warning, "‘\(variant)’ has no downloadable model",
                  ModelDownloader.DLError.subtitleUnavailable.localizedDescription)
            return
        }
        let confirm = NSAlert()
        confirm.messageText = "Download code-switching models?"
        confirm.informativeText = "Fetches the \(variant) Swedish model, whisper-large-v3, and the VAD model (≈2 GB total) into ~/.ghostie/models/. Files already present are skipped. You can keep using Settings while it runs; closing this window cancels it."
        confirm.addButton(withTitle: "Download")
        confirm.addButton(withTitle: "Cancel")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }

        csDownloadBtn.isEnabled = false
        csDownloadBtn.title = "Downloading…"
        csDownloadStatus.stringValue = "Starting…"
        downloader.start(items, status: { [weak self] s in
            self?.csDownloadStatus.stringValue = s
        }, finish: { [weak self] err in
            guard let self else { return }
            self.csDownloadBtn.isEnabled = true
            self.csDownloadBtn.title = "Download models (~2 GB)…"
            if let err {
                self.csDownloadStatus.stringValue = "Download failed."
                self.alert(.critical, "Model download failed", err.localizedDescription)
                return
            }
            // Point the model fields at the canonical logical names so
            // resolution finds what we just downloaded.
            if self.csSvModel.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
                || self.csSvModel.stringValue == "kb-whisper-large" {
                self.csSvModel.stringValue = "kb-whisper-large"
            }
            if self.csEnModel.stringValue.trimmingCharacters(in: .whitespaces).isEmpty
                || self.csEnModel.stringValue == "whisper-large-v3" {
                self.csEnModel.stringValue = "whisper-large-v3"
            }
            if self.vadField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty {
                self.vadField.stringValue = "\(Config.modelsDir)/ggml-silero-v5.1.2.bin"
            }
            self.csDownloadStatus.stringValue =
                "✓ Models ready. Tick “Enable code-switching” above, then Save."
        })
    }

    private func alert(_ style: NSAlert.Style, _ title: String, _ info: String) {
        let a = NSAlert()
        a.alertStyle = style
        a.messageText = title
        a.informativeText = info
        a.runModal()
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

        // Code-switching (start from loadRaw so advanced keys are preserved).
        cfg.codeSwitch.enabled = csEnable.state == .on
        let langs = csLanguages.stringValue
            .split(whereSeparator: { $0 == "," || $0 == " " })
            .map { $0.lowercased() }.filter { !$0.isEmpty }
        if langs.count >= 2 { cfg.codeSwitch.languages = langs }
        cfg.codeSwitch.dominantLanguage = csDominant.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.codeSwitch.modelPerLanguage["sv"] = csSvModel.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.codeSwitch.modelPerLanguage["en"] = csEnModel.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.codeSwitch.kbWhisperVariant = csVariant.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.codeSwitch.promptSv = csPromptSv.stringValue
        cfg.codeSwitch.promptEn = csPromptEn.stringValue
        if let v = Double(csPriorStrength.stringValue) {
            cfg.codeSwitch.crossTrackPriorStrength = min(1.0, max(0.5, v))
        }
        if let v = Int(csMinSwitch.stringValue) { cfg.codeSwitch.minSwitchSegments = max(1, v) }
        if let v = Int(csWindowMe.stringValue) { cfg.codeSwitch.smoothingWindowMe = max(1, v) }
        if let v = Int(csWindowPart.stringValue) { cfg.codeSwitch.smoothingWindowParticipants = max(1, v) }

        if cfg.save() {
            onSave(Config.load())
        }
        window?.close()
    }
}

/// Document view for a scrollable tab — flipped so content is laid out from
/// the top and the tab opens scrolled to the top, not the bottom.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
