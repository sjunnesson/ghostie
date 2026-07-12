import AppKit

// MARK: - Pane: About

final class AboutPane: NSView {
    init(openReleases: @escaping () -> Void) {
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
        let header = PageHeaderView(title: "About Ghostie",
                                    subtitle: "What Ghostie does, what's running on this Mac, and the licences it ships with.")
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = GroupCard()
        let v = "\(Updater.runningVersion())"
        let signed = Updater.runningBuildSupportsOTA()
        let macVer = ProcessInfo.processInfo.operatingSystemVersionString
        card.addRow(RowBuilder.row(
            label: "Version",
            sub: signed ? "\(v) · official signed release"
                        : "\(v) · built from source",
            control: NSTextField(labelWithString: v).styledAsMono()))
        card.addRow(RowBuilder.row(
            label: "macOS", sub: macVer,
            control: StatusBadgeView(kind: .ok, label: "Supported")))
        let target = ActionTarget(openReleases)
        let btn = StyledButton(title: "Open releases", target: target,
                               action: #selector(ActionTarget.fire))
        objc_setAssociatedObject(btn, &ActionTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        card.addRow(RowBuilder.row(
            label: "Open-source bits",
            sub: "Ghostie itself is MIT. It stands on Whisper.cpp (MIT), KB-Whisper (Apache 2.0), and Silero VAD (MIT).",
            control: btn), last: true)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}
