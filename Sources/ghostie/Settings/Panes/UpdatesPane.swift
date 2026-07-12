import AppKit
import ServiceManagement

// MARK: - Pane: Updates

final class UpdatesPane: NSView {
    enum DisplayStatus {
        case unknown(version: String)
        case upToDate(version: String)
        case available(from: String, to: String, notes: String)
        case unsupported
        case failed(String)
    }

    private let cfg: Config
    private let onCheckNow: () -> Void
    private let changes: ((inout Config) -> Void) -> Void

    private let heroTile = NSView()
    /// Last hero-tile color, kept so a light/dark switch can re-resolve the
    /// `cgColor` snapshot without waiting for the next `show(status:)`.
    private var heroBg: NSColor = Theme.chipBg
    private func setHeroBg(_ c: NSColor) {
        heroBg = c
        heroTile.layer?.backgroundColor = themedCG(c)
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        heroTile.layer?.backgroundColor = themedCG(heroBg)
    }
    private let heroSymbol = NSImageView()
    private let heroTitle = NSTextField(labelWithString: "")
    // Wrapping label — when the unsupported-build hero subtitle is set
    // ("This copy of Ghostie wasn't signed by us, so it can't update itself
    // safely. Grab the latest from the GitHub releases page."), a non-
    // wrapping label's intrinsic single-line width was pushing the entire
    // window wider on every visit to Updates.
    private let heroSub = NSTextField(wrappingLabelWithString: "")
    private let checkBtn: StyledButton

    init(cfg: Config, onCheckNow: @escaping () -> Void,
         changes: @escaping ((inout Config) -> Void) -> Void) {
        self.cfg = cfg
        self.onCheckNow = onCheckNow
        self.changes = changes
        self.checkBtn = StyledButton(title: "Check now", target: nil, action: nil)
        super.init(frame: .zero)
        build()
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
        let header = PageHeaderView(title: "Updates",
                                    subtitle: "How Ghostie checks for new releases and how it verifies them before installing.")
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let card = GroupCard()
        let hero = NSView()
        hero.translatesAutoresizingMaskIntoConstraints = false
        heroTile.translatesAutoresizingMaskIntoConstraints = false
        heroTile.wantsLayer = true
        heroTile.layer?.cornerRadius = 10
        heroSymbol.translatesAutoresizingMaskIntoConstraints = false

        heroTitle.font = .systemFont(ofSize: 14, weight: .semibold)
        heroTitle.textColor = Theme.text
        heroTitle.translatesAutoresizingMaskIntoConstraints = false

        heroSub.font = .systemFont(ofSize: 12)
        heroSub.textColor = Theme.text2
        heroSub.translatesAutoresizingMaskIntoConstraints = false
        heroSub.maximumNumberOfLines = 2
        heroSub.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        heroSub.setContentHuggingPriority(.defaultLow, for: .horizontal)

        heroTile.addSubview(heroSymbol)
        let textStack = NSStackView(views: [heroTitle, heroSub])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let checkTarget = ActionTarget { [weak self] in self?.onCheckNow() }
        checkBtn.target = checkTarget
        checkBtn.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(checkBtn, &ActionTarget.key, checkTarget, .OBJC_ASSOCIATION_RETAIN)

        hero.addSubview(heroTile)
        hero.addSubview(textStack)
        hero.addSubview(checkBtn)
        NSLayoutConstraint.activate([
            heroTile.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: 14),
            heroTile.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
            heroTile.widthAnchor.constraint(equalToConstant: 44),
            heroTile.heightAnchor.constraint(equalToConstant: 44),
            heroSymbol.centerXAnchor.constraint(equalTo: heroTile.centerXAnchor),
            heroSymbol.centerYAnchor.constraint(equalTo: heroTile.centerYAnchor),
            heroSymbol.widthAnchor.constraint(equalToConstant: 22),
            heroSymbol.heightAnchor.constraint(equalToConstant: 22),
            textStack.leadingAnchor.constraint(equalTo: heroTile.trailingAnchor, constant: 14),
            textStack.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: checkBtn.leadingAnchor, constant: -12),
            checkBtn.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -14),
            checkBtn.centerYAnchor.constraint(equalTo: hero.centerYAnchor),
            hero.topAnchor.constraint(equalTo: heroTile.topAnchor, constant: -14),
            hero.bottomAnchor.constraint(equalTo: heroTile.bottomAnchor, constant: 14)
        ])
        card.addRow(hero)

        card.addRow(buildToggleRow(
            label: "Check on its own",
            sub: "Ghostie peeks at GitHub about once a day and just after launch.",
            on: cfg.autoCheckUpdates) { [weak self] on in
                self?.changes { c in c.autoCheckUpdates = on }
            })
        card.addRow(buildStartAtLoginRow(), last: true)
        stack.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        // Initial state — no GitHub round-trip happens on window open, so
        // don't claim "You're up to date". Show the running version with a
        // neutral prompt to check; the user clicks Check now to verify.
        if Updater.runningBuildSupportsOTA() {
            show(status: .unknown(version: "\(Updater.runningVersion())"))
        } else {
            show(status: .unsupported)
        }
    }

    private func buildToggleRow(label: String, sub: String, on: Bool,
                                onChange: @escaping (Bool) -> Void) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = on ? .on : .off
        let target = ToggleTarget { onChange(toggle.state == .on) }
        toggle.target = target
        toggle.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(toggle, &ToggleTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return RowBuilder.row(label: label, sub: sub, control: toggle)
    }

    private func buildStartAtLoginRow() -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        if #available(macOS 13.0, *) {
            toggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
        }
        let target = ToggleTarget {
            guard #available(macOS 13.0, *) else { return }
            do {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                let a = NSAlert()
                a.messageText = "Could not change login item"
                a.informativeText = error.localizedDescription
                a.runModal()
            }
            if #available(macOS 13.0, *) {
                toggle.state = (SMAppService.mainApp.status == .enabled) ? .on : .off
            }
        }
        toggle.target = target
        toggle.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(toggle, &ToggleTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return RowBuilder.row(
            label: "Open Ghostie when I log in",
            sub: "Skip the manual launch — Ghostie comes back to the menu bar every time you sign in.",
            control: toggle)
    }

    func setBusy(_ busy: Bool, statusText: String?) {
        checkBtn.isEnabled = !busy
        if let statusText {
            heroSub.stringValue = statusText
        }
    }

    func show(status: DisplayStatus) {
        switch status {
        case .unknown(let v):
            setHeroBg(Theme.chipBg)
            heroSymbol.image = NSImage(systemSymbolName: "arrow.clockwise",
                                       accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 20, weight: .regular))
            heroSymbol.contentTintColor = Theme.text2
            heroTitle.stringValue = "Ghostie \(v)"
            heroSub.stringValue = "Click Check now to see if there's a newer release."
            checkBtn.title = "Check now"
        case .upToDate(let v):
            setHeroBg(Theme.okSoft)
            heroSymbol.image = NSImage(systemSymbolName: "checkmark",
                                       accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
            heroSymbol.contentTintColor = Theme.ok
            heroTitle.stringValue = "You're on the latest"
            heroSub.stringValue = "Ghostie \(v)"
            checkBtn.title = "Check now"
        case .available(let from, let to, _):
            setHeroBg(Theme.infoSoft)
            heroSymbol.image = NSImage(systemSymbolName: "arrow.down.circle",
                                       accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
            heroSymbol.contentTintColor = Theme.info
            heroTitle.stringValue = "A new version is ready"
            heroSub.stringValue = "\(from) → \(to)"
            checkBtn.title = "Update"
        case .unsupported:
            setHeroBg(Theme.warnSoft)
            heroSymbol.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                       accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
            heroSymbol.contentTintColor = Theme.warn
            heroTitle.stringValue = "Can't update from here"
            heroSub.stringValue = "This copy of Ghostie wasn't signed by us, so it can't update itself safely. Grab the latest from the GitHub releases page."
            checkBtn.title = "Open Releases"
            // Repoint to releases page when the build can't OTA.
            let target = ActionTarget {
                NSWorkspace.shared.open(Updater.releasesPage)
            }
            checkBtn.target = target
            checkBtn.action = #selector(ActionTarget.fire)
            objc_setAssociatedObject(checkBtn, &ActionTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        case .failed(let e):
            setHeroBg(Theme.dangerSoft)
            heroSymbol.image = NSImage(systemSymbolName: "xmark.circle",
                                       accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 22, weight: .semibold))
            heroSymbol.contentTintColor = Theme.danger
            heroTitle.stringValue = "Couldn't reach GitHub"
            heroSub.stringValue = e
            checkBtn.title = "Try again"
        }
    }
}
