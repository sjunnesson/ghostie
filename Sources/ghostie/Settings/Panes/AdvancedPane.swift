import AppKit

// MARK: - Pane: Advanced

final class AdvancedPane: NSView {
    init(openConfig: @escaping () -> Void,
         revealData: @escaping () -> Void,
         runDiagnose: @escaping () -> Void,
         runSelftest: @escaping () -> Void,
         runDoctor: @escaping () -> Void,
         resetSettings: @escaping () -> Void) {
        super.init(frame: .zero)
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
        let header = PageHeaderView(title: "Developer",
                                    subtitle: "Where Ghostie keeps its files and how to poke at it from the terminal. Most people won't need anything here.")
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = GroupCard()
        card.addRow(rowWithButton(label: "Open the config file",
                                  sub: "~/.ghostie/config.json — every setting Ghostie remembers, in one editable file.",
                                  symbol: "doc.text",
                                  button: ("Open", .secondary, openConfig)))
        card.addRow(rowWithButton(label: "Show me the Ghostie folder",
                                  sub: "~/.ghostie — where models, queued calls, and recordings live.",
                                  symbol: "folder",
                                  button: ("Reveal", .secondary, revealData)))
        card.addRow(rowWithButton(label: "Watch the detector live",
                                  sub: "Opens a terminal and streams what Ghostie sees while deciding if a call is real.",
                                  symbol: "terminal",
                                  button: ("Run", .secondary, runDiagnose)))
        card.addRow(rowWithButton(label: "Run a health check",
                                  sub: "Opens a terminal and reports whether Whisper, Claude and the permissions are all set up.",
                                  symbol: "stethoscope",
                                  button: ("Run", .secondary, runDoctor)))
        card.addRow(rowWithButton(label: "Run the self-test",
                                  sub: "Opens a terminal and replays the internal regression suite. Useful after editing Ghostie.",
                                  symbol: "checkmark.shield",
                                  button: ("Run", .secondary, runSelftest)))
        card.addRow(rowWithButton(label: "Reset all settings",
                                  sub: "Puts every setting back to its default. Your notes, the queue, and downloaded models stay.",
                                  symbol: nil,
                                  danger: true,
                                  button: ("Reset…", .danger, resetSettings)), last: true)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rowWithButton(label: String, sub: String,
                               symbol: String?,
                               danger: Bool = false,
                               button: (title: String, kind: ButtonKind, action: () -> Void))
        -> NSView {
        let target = ActionTarget { button.action() }
        let b = StyledButton(title: button.title, target: target, action: #selector(ActionTarget.fire))
        b.kind = button.kind
        objc_setAssociatedObject(b, &ActionTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return RowBuilder.row(label: label, sub: sub,
                              leadingSymbol: symbol,
                              leadingTint: symbol == nil ? nil : Theme.text2,
                              control: b, danger: danger)
    }
}
