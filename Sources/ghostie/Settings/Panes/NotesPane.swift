import AppKit

// MARK: - Pane: Notes

final class NotesPane: NSView {
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
