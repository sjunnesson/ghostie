import AppKit
import AVFoundation

/// A real Settings window (no more "open the JSON"). Edits the on-disk config,
/// saves it, and applies the change to the running engine immediately.
final class SettingsWindow: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let onSave: (Config) -> Void
    /// Live engine (menu-bar app) so a Settings-initiated update is gated on
    /// an active call. nil in the standalone `ghostie settings` process.
    private weak var engine: Engine?
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
    private let downloader = ModelDownloader()

    // Transcription tab v2. One column, three sections (Mode, Quality, Models
    // on disk). Advanced knobs and prompt edits live in config.json — kept off
    // the UI deliberately. The hidden NSTextFields below still hold their
    // values so Save round-trips them unchanged.
    private let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let whisperModelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let singleModeBlock = NSStackView()
    private let codeswitchModeBlock = NSStackView()

    // Per-model row UI. Keyed by a stable identifier ("base", "large-v3",
    // "kb", "vad") rather than filename so the KB row survives a variant
    // change. Built on Settings open; updated by `refreshModelRow(_:)`.
    private struct ModelRowViews {
        let status: NSTextField
        let action: NSButton
    }
    private var modelRows: [String: ModelRowViews] = [:]
    /// Set to a key while that single row's download is in flight, so
    /// per-row downloads serialize without a global "everything disabled".
    private var inflightModelKey: String?

    // Updates.
    private let autoUpdateCheck = NSButton(
        checkboxWithTitle: "Automatically check for updates (about once a day)",
        target: nil, action: nil)
    private let updateCheckBtn = NSButton(title: "Check Now…",
                                          target: nil, action: nil)
    private let updateStatus = NSTextField(wrappingLabelWithString: "")
    private let updater = Updater()

    init(engine: Engine? = nil, onSave: @escaping (Config) -> Void) {
        self.engine = engine
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
        updater.cancel()
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

        // `removeAllItems` first — `buildForm` re-runs on every Settings reopen
        // and `addItems` appends, so without this the lists grow each time.
        languageBox.removeAllItems()
        languageBox.addItems(withObjectValues: ["en", "auto", "sv", "de", "fr", "es", "it", "nl", "pt"])
        languageBox.stringValue = cfg.language
        languageBox.completes = true

        summaryBox.removeAllItems()
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
        csDominant.removeAllItems()
        csDominant.addItems(withObjectValues: ["en", "sv"])
        csDominant.stringValue = csc.dominantLanguage
        csDominant.completes = true
        csSvModel.stringValue = csc.modelPerLanguage["sv"] ?? "kb-whisper-large"
        csEnModel.stringValue = csc.modelPerLanguage["en"] ?? "whisper-large-v3"
        csVariant.removeAllItems()
        csVariant.addItems(withObjectValues: ["standard", "strict"])
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

        // ---- Updates -----------------------------------------------------
        autoUpdateCheck.state = cfg.autoCheckUpdates ? .on : .off
        updateStatus.font = .systemFont(ofSize: 11)
        updateStatus.textColor = .secondaryLabelColor
        updateCheckBtn.bezelStyle = .rounded
        updateCheckBtn.target = self
        updateCheckBtn.action = #selector(checkForUpdates)
        let otaOK = Updater.runningBuildSupportsOTA()
        autoUpdateCheck.isEnabled = otaOK
        updateCheckBtn.isEnabled = otaOK
        updateStatus.stringValue = otaOK
            ? "Current version: \(Updater.runningVersion())"
            : "This build can't self-update (not a notarized release). Download from GitHub Releases."

        // ---- Tabs --------------------------------------------------------
        let tabs = NSTabView()
        tabs.translatesAutoresizingMaskIntoConstraints = false
        tabs.addTabViewItem(tab("General", [
            field("Notes folder", pathControl(notesField, chooseDir: true)),
            keepAudio,
            saveTranscript,
            caption("Summaries are written here as markdown after each call."),
            section("Updates"),
            autoUpdateCheck,
            leftWrap(updateCheckBtn),
            updateStatus,
            caption("Updates come from GitHub Releases and are verified (Apple notarization + SHA-256) before installing. Installing quits and relaunches Ghostie; it never interrupts an active call. Only notarized Developer-ID builds can self-update.")
        ]))
        tabs.addTabViewItem(tab("Detection", [
            requireTeams,
            field("End call after Teams releases the mic", leftWrap(suffixed(endGrace, "seconds", width: 70))),
            field("Ignore calls shorter than", leftWrap(suffixed(minCall, "seconds", width: 70))),
            caption("A call ends when Teams continuously stops holding the microphone for this long. The grace window rides over brief drops — mute toggles, AirPods reconnecting, a quick Teams restart. This is not voice-activity detection; your own pauses do not count as the mic being released.")
        ]))
        tabs.addTabViewItem(tab("Permissions", permissionsTabContents()))

        // Mode-specific UI is built in two containers; the popup toggles which
        // is visible. The variant dropdown drives the KB row's status.
        csVariant.target = self
        csVariant.action = #selector(variantChanged)
        buildModeControls(currentlyCodeswitch: cfg.codeSwitch.enabled,
                          currentWhisperModelPath: cfg.whisperModel)

        tabs.addTabViewItem(tab("Transcription", [
            section("Mode"),
            leftWrap(sized(modePopup, 260)),

            singleModeBlock,
            codeswitchModeBlock,

            section("Quality"),
            cleanTranscript,
            caption("Silero VAD is used automatically when its model is on disk."),

            section("Models on disk"),
            makeModelRow(key: "base",     title: "Whisper base (English) · ~150 MB"),
            makeModelRow(key: "kb",       title: "KB-Whisper-large (Swedish) · ~1.1 GB"),
            makeModelRow(key: "large-v3", title: "Whisper large-v3 (English) · ~1.1 GB"),
            makeModelRow(key: "vad",      title: "Silero VAD · ~900 KB"),
            caption("Status comes from the verification sidecar written at download time. Hashes match Hugging Face's published SHA256."),

            caption("Prompts, smoothing and other tuning live in config.json — open with the button below.")
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

    /// Build the contents of the Permissions tab. Status is read once when
    /// the Settings window is built; reopen Settings to re-check after
    /// granting in System Settings.
    private func permissionsTabContents() -> [NSView] {
        let binaryPath = CommandLine.arguments[0]
        let isAppBundle = binaryPath.contains(".app/Contents/MacOS/")
        var rows: [NSView] = [
            caption("Ghostie needs three permissions from macOS. Microphone and Screen Recording are required for recording calls. Accessibility is optional and adds a third confirmation signal for call detection.")
        ]
        if !isAppBundle {
            let warn = caption("⚠︎  This Settings window was opened from \(binaryPath). That's an ad-hoc-signed CLI build; macOS TCC keys grants to a different identity than /Applications/Ghostie.app, so permissions granted here will not transfer to the installed app. Quit and launch Ghostie.app from Finder to manage real grants.")
            warn.textColor = .systemOrange
            rows.append(warn)
        }
        rows.append(section("Required"))
        rows.append(permissionRow(
            "Microphone",
            granted: AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
            deniedExplicit: AVCaptureDevice.authorizationStatus(for: .audio) == .denied,
            detail: "Captures your voice during a call (the 'Me' track). The first call detection triggers a system prompt the first time.",
            openPaneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
        rows.append(permissionRow(
            "Screen Recording",
            granted: CGPreflightScreenCaptureAccess(),
            deniedExplicit: false,
            detail: "Captures system audio (the other participants' voices) via ScreenCaptureKit. The 2x2 video stream attached to the audio capture is dropped, not recorded.",
            openPaneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))
        rows.append(section("Optional"))
        rows.append(permissionRow(
            "Accessibility",
            granted: AXIsProcessTrusted(),
            deniedExplicit: false,
            detail: "Reads Teams' top-level window titles and roles to confirm a meeting window is open. Adds a third corroborator for call detection; without it the detector relies on audio I/O attribution alone.",
            openPaneURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))
        return rows
    }

    /// One row per permission: status pill + label + short rationale + a
    /// button that deep-links into the relevant System Settings pane.
    private func permissionRow(_ title: String,
                               granted: Bool,
                               deniedExplicit: Bool,
                               detail: String,
                               openPaneURL: String) -> NSView {
        let badge = NSTextField(labelWithString: granted ? "✓ granted"
                                : deniedExplicit ? "✗ DENIED"
                                : "✗ not granted")
        badge.font = .systemFont(ofSize: 11, weight: .semibold)
        badge.textColor = granted ? .systemGreen : (deniedExplicit ? .systemRed : .systemOrange)

        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)

        let rationale = NSTextField(wrappingLabelWithString: detail)
        rationale.font = .systemFont(ofSize: 11)
        rationale.textColor = .secondaryLabelColor

        let button = NSButton(title: "Open System Settings",
                              target: self, action: #selector(openPermissionPane(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.toolTip = openPaneURL
        button.identifier = NSUserInterfaceItemIdentifier(openPaneURL)
        button.isHidden = granted

        for v in [badge, label, rationale, button] {
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(label)
        row.addSubview(badge)
        row.addSubview(rationale)
        row.addSubview(button)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: row.topAnchor),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            badge.firstBaselineAnchor.constraint(equalTo: label.firstBaselineAnchor),
            badge.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 10),
            rationale.topAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
            rationale.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            rationale.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            button.topAnchor.constraint(equalTo: rationale.bottomAnchor, constant: 4),
            button.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            button.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        // When granted, there's no button — bind the bottom to rationale instead.
        if granted {
            NSLayoutConstraint.activate([
                rationale.bottomAnchor.constraint(equalTo: row.bottomAnchor)
            ])
        }
        return row
    }

    @objc private func openPermissionPane(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let url = URL(string: raw) else { return }
        NSWorkspace.shared.open(url)
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

    // MARK: - Mode controls (Single language ↔ Code-switching)

    /// Populate the mode popup + the two per-mode blocks. Called once during
    /// `buildForm`. The mode popup drives which block is visible; the rest is
    /// just layout.
    private func buildModeControls(currentlyCodeswitch: Bool,
                                   currentWhisperModelPath: String) {
        modePopup.removeAllItems()
        modePopup.addItems(withTitles: ["Single language", "Code-switching (Swedish ↔ English)"])
        modePopup.target = self
        modePopup.action = #selector(modeChanged)
        modePopup.selectItem(at: currentlyCodeswitch ? 1 : 0)

        // Single-mode whisper model popup. Each item carries its `Model` (or
        // nil for the "Custom" sentinel) via `representedObject`, so save just
        // reads model.destPath without re-mapping titles.
        whisperModelPopup.removeAllItems()
        func addModelItem(_ title: String, _ model: Model?) {
            let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            mi.representedObject = model
            whisperModelPopup.menu?.addItem(mi)
        }
        addModelItem("Whisper base (English) · 150 MB", Models.baseEnglish)
        addModelItem("Whisper large-v3 (multilingual) · 1.1 GB", Models.largeV3)
        // If the user's config points at something unrecognized, surface it as
        // "Custom" so they don't get silently overwritten on save.
        let isKnown = currentWhisperModelPath == Models.baseEnglish.destPath
                   || currentWhisperModelPath == Models.largeV3.destPath
        if !isKnown && !currentWhisperModelPath.isEmpty {
            addModelItem("Custom (\(URL(fileURLWithPath: currentWhisperModelPath).lastPathComponent))", nil)
            whisperModelPopup.selectItem(at: 2)
        } else if currentWhisperModelPath == Models.largeV3.destPath {
            whisperModelPopup.selectItem(at: 1)
        } else {
            whisperModelPopup.selectItem(at: 0)
        }
        whisperModelPopup.target = self
        whisperModelPopup.action = #selector(whisperModelChanged)

        // ---- Single-language block --------------------------------------
        singleModeBlock.orientation = .vertical
        singleModeBlock.alignment = .leading
        singleModeBlock.spacing = 12
        singleModeBlock.setHuggingPriority(.defaultLow, for: .horizontal)
        singleModeBlock.addArrangedSubview(field("Model", leftWrap(sized(whisperModelPopup, 360))))
        singleModeBlock.addArrangedSubview(field("Language", leftWrap(sized(languageBox, 120))))

        // ---- Code-switching block ---------------------------------------
        codeswitchModeBlock.orientation = .vertical
        codeswitchModeBlock.alignment = .leading
        codeswitchModeBlock.spacing = 12
        codeswitchModeBlock.setHuggingPriority(.defaultLow, for: .horizontal)
        codeswitchModeBlock.addArrangedSubview(
            field("Tie-breaker language", leftWrap(sized(csDominant, 120))))
        codeswitchModeBlock.addArrangedSubview(
            field("Swedish transcription style", leftWrap(sized(csVariant, 160))))
        codeswitchModeBlock.addArrangedSubview(
            caption("standard, balanced for notes · strict, verbatim with filler."))

        // Both blocks are always in the tab; toggle visibility based on mode.
        applyModeVisibility()
    }

    private func applyModeVisibility() {
        let codeswitch = modePopup.indexOfSelectedItem == 1
        singleModeBlock.isHidden = codeswitch
        codeswitchModeBlock.isHidden = !codeswitch
    }

    @objc private func modeChanged() {
        applyModeVisibility()
    }

    @objc private func whisperModelChanged() {
        // No-op for now; save() reads the popup's current representedObject.
        // The handler exists so future UX (e.g. live status under the picker)
        // can hang off it without restructuring.
    }

    // MARK: - Per-model rows (Models on disk)

    /// Resolve the row key to the Model it currently represents. The "kb"
    /// row depends on the variant dropdown, so it has to recompute each time.
    private func modelForKey(_ key: String) -> Model? {
        switch key {
        case "base":     return Models.baseEnglish
        case "large-v3": return Models.largeV3
        case "vad":      return Models.sileroVAD
        case "kb":
            let variant = csVariant.stringValue.trimmingCharacters(in: .whitespaces)
            return Models.kbWhisperLarge(variant: variant.isEmpty ? "standard" : variant)
        default:         return nil
        }
    }

    /// Build a row: title on the left, status in the middle, action button on
    /// the right. Same pattern for every model. Stored in `modelRows` by key.
    private func makeModelRow(key: String, title: String) -> NSView {
        let name = NSTextField(labelWithString: title)
        name.font = .systemFont(ofSize: 12)
        let status = NSTextField(labelWithString: "—")
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        let action = NSButton(title: "—", target: self,
                              action: #selector(modelRowAction(_:)))
        action.bezelStyle = .rounded
        action.identifier = NSUserInterfaceItemIdentifier(key)
        modelRows[key] = ModelRowViews(status: status, action: action)

        let row = NSStackView(views: [name, status, action])
        row.orientation = .horizontal
        row.spacing = 12
        row.alignment = .centerY
        row.distribution = .fill
        name.setContentHuggingPriority(.defaultLow, for: .horizontal)
        name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        status.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        action.setContentHuggingPriority(.required, for: .horizontal)
        DispatchQueue.main.async { [weak self] in self?.refreshModelRow(key) }
        return row
    }

    /// Synchronously read the on-disk state via the sidecar and update the row.
    /// No network and no full re-hash here — that's what the action button is
    /// for (Verify / Re-verify do the heavy work in the background).
    private func refreshModelRow(_ key: String) {
        guard let row = modelRows[key] else { return }
        if inflightModelKey == key { return }   // mid-download; leave as-is
        guard let model = modelForKey(key) else {
            row.status.stringValue = "no downloadable model for this variant"
            row.action.title = "—"
            row.action.isEnabled = false
            return
        }
        let h = ModelDownloader.health(for: [model])[0]
        row.status.stringValue = h.state.summary
        row.action.isEnabled = inflightModelKey == nil
        switch h.state {
        case .ok:                              row.action.title = "Re-verify"
        case .missing:                         row.action.title = "Download"
        case .noSidecar:                       row.action.title = "Verify"
        case .sizeWrong, .hashMismatch:        row.action.title = "Re-download"
        }
    }

    private func refreshAllModelRows() {
        for key in modelRows.keys { refreshModelRow(key) }
    }

    @objc private func variantChanged() {
        // The kb row's filename + status both depend on the variant.
        refreshModelRow("kb")
    }

    @objc private func modelRowAction(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue,
              let model = modelForKey(key) else { return }
        let h = ModelDownloader.health(for: [model])[0]
        switch h.state {
        case .missing, .sizeWrong, .hashMismatch:
            startDownload(model, key: key)
        case .noSidecar:
            startAdopt(model, key: key)
        case .ok:
            startReverify(model, key: key)
        }
    }

    private func startDownload(_ model: Model, key: String) {
        guard inflightModelKey == nil else { return }
        inflightModelKey = key
        for k in modelRows.keys where k != key {
            modelRows[k]?.action.isEnabled = false
        }
        modelRows[key]?.status.stringValue = "Starting…"
        modelRows[key]?.action.title = "Downloading…"
        modelRows[key]?.action.isEnabled = false
        downloader.start(models: [model], status: { [weak self] s in
            self?.modelRows[key]?.status.stringValue = s
        }, finish: { [weak self] err in
            guard let self else { return }
            self.inflightModelKey = nil
            if let err {
                self.alert(.critical, "Download failed", err.localizedDescription)
            }
            self.refreshAllModelRows()
        })
    }

    /// HEAD + hash the existing on-disk file and write the sidecar if it
    /// matches. No re-download. Runs off the main queue because hashing 1 GB
    /// is a few seconds.
    private func startAdopt(_ model: Model, key: String) {
        guard inflightModelKey == nil else { return }
        modelRows[key]?.status.stringValue = "Verifying (HEAD + SHA256)…"
        modelRows[key]?.action.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = ModelDownloader.adopt(model)
            DispatchQueue.main.async { self?.refreshModelRow(key) }
        }
    }

    /// Re-hash an already-verified file against the cached sidecar etag.
    /// Catches local file corruption since the last verify. Same background
    /// dispatch as adopt.
    private func startReverify(_ model: Model, key: String) {
        guard inflightModelKey == nil else { return }
        modelRows[key]?.status.stringValue = "Re-hashing…"
        modelRows[key]?.action.isEnabled = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            _ = ModelDownloader.health(for: [model])
            DispatchQueue.main.async { self?.refreshModelRow(key) }
        }
    }

    @objc private func checkForUpdates() {
        if updater.isRunning { return }
        updateCheckBtn.isEnabled = false
        updateStatus.stringValue = "Checking…"
        updater.check(config: Config.load()) { [weak self] result in
            guard let self else { return }
            self.updateCheckBtn.isEnabled = true
            switch result {
            case .success(.upToDate(let cur)):
                self.updateStatus.stringValue = "You're up to date — Ghostie \(cur)."
            case .success(.skippedUnsupportedBuild):
                self.updateStatus.stringValue =
                    "This build can't self-update. Download from GitHub Releases."
            case .failure(let e):
                self.updateStatus.stringValue = "Check failed: \(e.localizedDescription)"
            case .success(.available(let r, let cur)):
                self.updateStatus.stringValue = "Update available: \(cur) → \(r.tag)"
                let a = NSAlert()
                a.messageText = "Update Ghostie to \(r.tag)?"
                a.informativeText = (r.notes.isEmpty ? "" : r.notes + "\n\n")
                    + "Ghostie will download and verify the update, then quit "
                    + "and relaunch. It won't interrupt an active call."
                a.addButton(withTitle: "Update Now")
                a.addButton(withTitle: "Later")
                guard a.runModal() == .alertFirstButtonReturn else { return }
                self.updateCheckBtn.isEnabled = false
                self.updateCheckBtn.title = "Updating…"
                self.updater.downloadAndInstall(r, engine: self.engine,
                    status: { [weak self] s in self?.updateStatus.stringValue = s },
                    finish: { [weak self] err in
                        guard let self else { return }
                        self.updateCheckBtn.isEnabled = true
                        self.updateCheckBtn.title = "Check Now…"
                        if let err {
                            self.alert(.critical, "Update failed",
                                       err.localizedDescription)
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
        // Single-mode whisper model comes from the popup; falls back to the
        // existing config value if the user selected the "Custom" sentinel.
        if let m = whisperModelPopup.selectedItem?.representedObject as? Model {
            cfg.whisperModel = m.destPath
        }
        cfg.language = languageBox.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.cleanTranscript = cleanTranscript.state == .on
        cfg.initialPrompt = promptView.string
        // VAD model is always the manifest path now (single source of truth).
        cfg.vadModel = Models.sileroVAD.destPath
        cfg.summaryModel = summaryBox.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.claudeBinary = claudeField.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.autoCheckUpdates = autoUpdateCheck.state == .on

        // Mode toggles codeSwitch.enabled. The advanced codeswitch values
        // (prompts, smoothing knobs) are preserved untouched — they round-trip
        // through cfg loaded above. Only the user-facing knobs are written here.
        cfg.codeSwitch.enabled = modePopup.indexOfSelectedItem == 1
        cfg.codeSwitch.languages = ["sv", "en"]
        cfg.codeSwitch.dominantLanguage = csDominant.stringValue.trimmingCharacters(in: .whitespaces)
        cfg.codeSwitch.modelPerLanguage["sv"] = "kb-whisper-large"
        cfg.codeSwitch.modelPerLanguage["en"] = "whisper-large-v3"
        cfg.codeSwitch.kbWhisperVariant = csVariant.stringValue.trimmingCharacters(in: .whitespaces)

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
