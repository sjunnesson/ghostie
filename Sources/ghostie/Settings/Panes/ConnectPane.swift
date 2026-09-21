import AppKit

// MARK: - Pane: MCP

/// Connecting Ghostie's MCP server to whatever assistant the user runs.
///
/// The pane exists so that nobody has to find a JSON file buried in
/// `~/Library/Application Support`, get an absolute binary path right inside
/// it, and guess that the app needs restarting. Installed clients get a
/// button; everything else gets the block to paste, because MCP is an open
/// protocol and the list of things that speak it will always be longer than
/// the list Ghostie knows by name.
///
/// The privacy card is the other reason the pane exists. Everything else
/// Ghostie does happens on this machine, and connecting it to an assistant is
/// the one action that can send a transcript somewhere else. Saying so where
/// the switch is, is the only place saying it is any use.
final class ConnectPane: NSView {
    private let cfg: Config
    private let reveal: (String) -> Void

    private var clientRows: [ClientRow] = []
    private let indexLabel = NSTextField(labelWithString: "")
    private let clientsContainer = NSStackView()

    init(cfg: Config, reveal: @escaping (String) -> Void) {
        self.cfg = cfg
        self.reveal = reveal
        super.init(frame: .zero)
        build()
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

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
            title: "MCP",
            subtitle: "Model Context Protocol — the open standard for letting an AI assistant read your call notes. Connect one below and it can pull up your last call, find an older one, or search across all of them.")
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Installed clients are rebuilt on every refresh: someone can install
        // Cursor while this window is open, and a row that never appears is
        // indistinguishable from one that is not supported.
        clientsContainer.orientation = .vertical
        clientsContainer.alignment = .leading
        clientsContainer.spacing = 22
        clientsContainer.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(clientsContainer)
        clientsContainer.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Everything Ghostie does not write itself.
        let manual = GroupCard(title: "Any other client")
        let copyTarget = ActionTarget { [weak self] in self?.copySnippet(key: "mcpServers") }
        let copyBtn = StyledButton(title: "Copy", target: copyTarget,
                                   action: #selector(ActionTarget.fire))
        copyBtn.kind = .secondary
        objc_setAssociatedObject(copyBtn, &ActionTarget.key, copyTarget, .OBJC_ASSOCIATION_RETAIN)
        manual.addRow(RowBuilder.row(
            label: "Copy configuration",
            sub: "The standard `mcpServers` block, with this copy's path already in it. Works in Zed, Cline, Goose — anything taking a command-and-args server.",
            leadingSymbol: "doc.on.doc.fill", leadingTint: Theme.accent,
            control: copyBtn))

        let vscTarget = ActionTarget { [weak self] in self?.copySnippet(key: "servers") }
        let vscBtn = StyledButton(title: "Copy", target: vscTarget,
                                  action: #selector(ActionTarget.fire))
        vscBtn.kind = .secondary
        objc_setAssociatedObject(vscBtn, &ActionTarget.key, vscTarget, .OBJC_ASSOCIATION_RETAIN)
        manual.addRow(RowBuilder.row(
            label: "Copy for VS Code",
            sub: "The same block under `servers`, the one key VS Code spells differently. Use it for a custom profile.",
            leadingSymbol: "chevron.left.forwardslash.chevron.right", leadingTint: Theme.accent,
            control: vscBtn))

        let cmdTarget = ActionTarget { [weak self] in self?.copyCommand() }
        let cmdBtn = StyledButton(title: "Copy", target: cmdTarget,
                                  action: #selector(ActionTarget.fire))
        cmdBtn.kind = .secondary
        objc_setAssociatedObject(cmdBtn, &ActionTarget.key, cmdTarget, .OBJC_ASSOCIATION_RETAIN)
        manual.addRow(RowBuilder.row(
            label: "Copy the command",
            sub: MCPSetup.abbreviate(MCPSetup.executablePath()) + " mcp",
            leadingSymbol: "terminal.fill", leadingTint: Theme.accent,
            control: cmdBtn), last: true)
        stack.addArrangedSubview(manual)
        manual.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let privacy = GroupCard(title: "What this shares")
        privacy.addRow(RowBuilder.row(
            label: "Your recordings stay here",
            sub: "Audio is never uploaded. Transcription runs on this Mac, as it always has.",
            leadingSymbol: "lock.fill", leadingTint: Theme.accent))
        privacy.addRow(RowBuilder.row(
            label: "Notes go wherever that assistant goes",
            sub: "Sent only when you ask about a call, and only to that assistant's provider — nowhere at all if it runs a local model.",
            leadingSymbol: "arrow.up.forward.app.fill", leadingTint: Theme.accent))
        privacy.addRow(RowBuilder.row(
            label: "Reading only",
            sub: "The connection cannot start a recording, change a setting, or delete a note.",
            leadingSymbol: "eye.fill", leadingTint: Theme.accent), last: true)
        stack.addArrangedSubview(privacy)
        privacy.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let details = GroupCard(title: "Index")
        let rebuildTarget = ActionTarget { [weak self] in self?.rebuildIndex() }
        let rebuildBtn = StyledButton(title: "Rebuild", target: rebuildTarget,
                                      action: #selector(ActionTarget.fire))
        rebuildBtn.kind = .secondary
        objc_setAssociatedObject(rebuildBtn, &ActionTarget.key, rebuildTarget, .OBJC_ASSOCIATION_RETAIN)
        details.addRow(RowBuilder.row(
            label: "Calls an assistant can see",
            sub: "Updated after every call. Rebuild it if you have moved or edited notes by hand.",
            control: NSStackView(views: [indexLabel, rebuildBtn]).asRowControl()))

        let revealTarget = ActionTarget { [weak self] in self?.reveal(TranscriptIndex.root) }
        let revealBtn = StyledButton(title: "Reveal", target: revealTarget,
                                     action: #selector(ActionTarget.fire))
        revealBtn.kind = .secondary
        objc_setAssociatedObject(revealBtn, &ActionTarget.key, revealTarget, .OBJC_ASSOCIATION_RETAIN)
        details.addRow(RowBuilder.row(
            label: "Index folder",
            sub: MCPSetup.abbreviate(TranscriptIndex.root),
            control: revealBtn), last: true)
        stack.addArrangedSubview(details)
        details.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    private func refresh() {
        let count = TranscriptIndex.summaries().count
        indexLabel.stringValue = "\(count) call\(count == 1 ? "" : "s")"
        indexLabel.textColor = Theme.text2
        rebuildClientRows()
    }

    private func rebuildClientRows() {
        clientsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        clientRows = []

        let installed = MCPSetup.installedClients(cfg)
        guard !installed.isEmpty else {
            // Not an error state: plenty of people will connect something
            // Ghostie has never heard of, which is what the card below is for.
            let empty = GroupCard()
            empty.addRow(RowBuilder.row(
                label: "No known assistant found on this Mac",
                sub: "Ghostie sets up Claude Desktop, Claude Code, Codex, Cursor, VS Code, Windsurf and LM Studio. For anything else, copy the configuration below.",
                leadingSymbol: "questionmark.circle.fill", leadingTint: Theme.accent), last: true)
            clientsContainer.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: clientsContainer.widthAnchor).isActive = true
            return
        }

        let card = GroupCard(title: "Found on this Mac")
        for (i, client) in installed.enumerated() {
            let row = ClientRow(client: client, cfg: cfg) { [weak self] in self?.refresh() }
            clientRows.append(row)
            card.addRow(row, last: i == installed.count - 1)
        }
        clientsContainer.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: clientsContainer.widthAnchor).isActive = true
    }

    private func copySnippet(key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(MCPSetup.configSnippet(key: key), forType: .string)
        flash("Configuration copied",
              MCPSetup.isTransientPath(MCPSetup.executablePath())
                ? "Note: this copy of Ghostie is running from a build folder, so the path in it is temporary."
                : "Paste it into your assistant's MCP settings.")
    }

    private func copyCommand() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(MCPSetup.executablePath()) mcp", forType: .string)
        flash("Command copied", "Point any MCP client at it as a stdio server.")
    }

    private func flash(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.runModal()
    }

    private func rebuildIndex() {
        let result = TranscriptIndex.rebuild(notesFolder: cfg.notesFolder)
        refresh()
        flash("Indexed \(result.indexed) call\(result.indexed == 1 ? "" : "s")",
              result.skipped > 0
                ? "\(result.skipped) file(s) in the notes folder could not be read as a call and were left alone."
                : "Every note in \(MCPSetup.abbreviate(cfg.notesFolder)) is now searchable.")
    }
}

// MARK: - One client's row

/// An installed client: what state it is in, and the button that changes it.
/// Re-reads its own state after every action rather than tracking it, because
/// the config it reflects can also be changed from outside the app (by
/// `ghostie connect`, by the client's own UI, or by hand).
private final class ClientRow: NSView {
    private let client: MCPSetup.Client
    private let cfg: Config
    private let onChange: () -> Void

    /// Held only so the closure driving the button is not deallocated the
    /// moment `refresh()` returns.
    private var buttonTarget: ActionTarget?
    private let container = NSStackView()

    init(client: MCPSetup.Client, cfg: Config, onChange: @escaping () -> Void) {
        self.client = client
        self.cfg = cfg
        self.onChange = onChange
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        container.orientation = .vertical
        container.alignment = .leading
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    func refresh() {
        container.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let status = MCPSetup.status(client, config: cfg)
        let target = ActionTarget { [weak self] in self?.act(from: status) }
        buttonTarget = target
        let blocked = MCPSetup.blockingIssue(client) != nil
        let button = StyledButton(title: buttonTitle(for: status), target: target,
                                  action: #selector(ActionTarget.fire))
        button.kind = status.isConnected ? .secondary : .primary
        button.isEnabled = { if case .unavailable = status { return false }; return true }()
        objc_setAssociatedObject(button, &ActionTarget.key, target, .OBJC_ASSOCIATION_RETAIN)

        let badge = blocked
            ? StatusBadgeView(kind: .warn, label: "Quit \(client.displayName)")
            : badgeView(for: status)
        let control = NSStackView(views: [badge, button]).asRowControl()
        let row = RowBuilder.row(
            label: client.displayName,
            // While it is running the row is read-only, so say which of the
            // two situations it is: already set up, or waiting to be.
            sub: blocked
                ? (status.isConnected
                    ? "Connected. Quit it before changing this, or the entry is lost on its next save."
                    : "Running — quit it first, or it will discard the entry the next time it saves.")
                : subtitle(for: status),
            leadingSymbol: client.symbol,
            leadingTint: Theme.accent,
            control: control)
        container.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
    }

    private func buttonTitle(for status: MCPSetup.Status) -> String {
        switch status {
        case .connected: return "Disconnect"
        case .connectedToOtherPath: return "Reconnect"
        case .notConnected, .unavailable: return "Connect"
        }
    }

    private func badgeView(for status: MCPSetup.Status) -> NSView {
        switch status {
        case .connected: return StatusBadgeView(kind: .ok, label: "Connected")
        case .connectedToOtherPath: return StatusBadgeView(kind: .warn, label: "Out of date")
        case .notConnected: return StatusBadgeView(kind: .muted, label: "Not connected")
        case .unavailable: return StatusBadgeView(kind: .muted, label: "Unavailable")
        }
    }

    private func subtitle(for status: MCPSetup.Status) -> String {
        switch status {
        case .connected:
            return client.connectedHint
        case .connectedToOtherPath(let path):
            // The usual cause: connected from a development build, then the
            // app moved to /Applications. The old path still "works" until
            // that build directory is cleaned, so be specific.
            return "Pointing at a different copy of Ghostie (\(MCPSetup.abbreviate(path))). Reconnect to point it here."
        case .notConnected:
            return client.connectHint
        case .unavailable(let why):
            return why
        }
    }

    private func act(from status: MCPSetup.Status) {
        let connecting = !(status == .connected)
        let result = connecting
            ? MCPSetup.connect(client, config: cfg)
            : MCPSetup.disconnect(client, config: cfg)

        let alert = NSAlert()
        switch result {
        case .success(let message):
            alert.messageText = connecting
                ? "Connected to \(client.displayName)"
                : "Disconnected from \(client.displayName)"
            var body = message
            if connecting {
                body += " " + client.connectHint
                if MCPSetup.isTransientPath(MCPSetup.executablePath()) {
                    body += "\n\n⚠️ This copy of Ghostie is running from a build folder. "
                    body += "Install the app and connect again, or the link will break when that folder is cleaned."
                }
                let count = TranscriptIndex.summaries().count
                body += count == 0
                    ? "\n\nNo calls are indexed yet — Ghostie will index each one as it records it."
                    : "\n\n\(count) call\(count == 1 ? "" : "s") ready to read. Try: “what was my last call about?”"
            }
            alert.informativeText = body
        case .failure(let error):
            alert.alertStyle = .warning
            alert.messageText = "Could not \(connecting ? "connect to" : "disconnect from") \(client.displayName)"
            alert.informativeText = error.localizedDescription
        }
        alert.runModal()
        onChange()
    }
}

private extension NSStackView {
    /// The horizontal badge+button pairing every row in this pane uses.
    func asRowControl() -> NSStackView {
        orientation = .horizontal
        spacing = 8
        alignment = .centerY
        return self
    }
}
