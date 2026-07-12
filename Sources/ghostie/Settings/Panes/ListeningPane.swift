import AppKit
import QuartzCore

// MARK: - Pane: Listening

final class ListeningPane: NSView {

    private let cfg: Config
    private let engineState: () -> EngineState
    private let onPause: () -> Void
    private let changes: ((inout Config) -> Void) -> Void

    private var permsCard: NSView?
    private var liveStatusRow: LiveStatusRow!
    private var permsContainer = NSStackView()
    private var advancedContainer = NSStackView()
    private var paneStack = NSStackView()
    private var timer: Timer?
    private var disclosureToken: NSObjectProtocol?

    init(cfg: Config,
         engineState: @escaping () -> EngineState,
         onPause: @escaping () -> Void,
         changes: @escaping ((inout Config) -> Void) -> Void) {
        self.cfg = cfg
        self.engineState = engineState
        self.onPause = onPause
        self.changes = changes
        super.init(frame: .zero)
        build()
        disclosureToken = NotificationCenter.default.addObserver(
            forName: Disclosure.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.refreshAdvanced()
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        timer?.invalidate()
        if let disclosureToken { NotificationCenter.default.removeObserver(disclosureToken) }
    }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false
        paneStack.orientation = .vertical
        paneStack.alignment = .leading
        paneStack.spacing = 22
        paneStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(paneStack)
        NSLayoutConstraint.activate([
            paneStack.topAnchor.constraint(equalTo: topAnchor),
            paneStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            paneStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            paneStack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let header = PageHeaderView(title: "Listening",
                                    subtitle: "When Ghostie watches for Teams calls and how it confirms one is real.")
        paneStack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true

        permsContainer.orientation = .vertical
        permsContainer.alignment = .leading
        permsContainer.spacing = 22
        permsContainer.translatesAutoresizingMaskIntoConstraints = false
        paneStack.addArrangedSubview(permsContainer)
        permsContainer.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true
        rebuildPermissions()

        // Live status card.
        liveStatusRow = LiveStatusRow(onPause: { [weak self] in self?.onPause() })
        let liveCard = GroupCard()
        liveCard.addRow(liveStatusRow, last: true)
        paneStack.addArrangedSubview(liveCard)
        liveCard.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true
        refreshLiveStatus(engineState())

        // Detection group. (Used to expose a "Require Microsoft Teams" toggle
        // here — removed because the new detector always requires a match
        // against `triggerBundleIds` and ignored the legacy flag.)
        let detection = GroupCard(title: "Detection")
        detection.addRow(buildStepperRow(
            label: "End-call grace",
            sub: "How long Teams must stay quiet before Ghostie decides the call has ended.",
            initial: Int(cfg.endGraceSeconds),
            range: 5...600,
            suffix: "s") { [weak self] v in
                self?.changes { c in c.endGraceSeconds = Double(v) }
            })
        detection.addRow(buildStepperRow(
            label: "Ignore short calls",
            sub: "Anything shorter than this gets thrown away without writing a note.",
            initial: Int(cfg.minCallSeconds),
            range: 0...600,
            suffix: "s") { [weak self] v in
                self?.changes { c in c.minCallSeconds = Double(v) }
            }, last: true)
        paneStack.addArrangedSubview(detection)
        detection.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true

        // Advanced container — driven by the global Disclosure toggle in the
        // sidebar; no per-pane disclosure footer.
        advancedContainer.orientation = .vertical
        advancedContainer.alignment = .leading
        advancedContainer.spacing = 22
        advancedContainer.translatesAutoresizingMaskIntoConstraints = false
        paneStack.addArrangedSubview(advancedContainer)
        advancedContainer.widthAnchor.constraint(equalTo: paneStack.widthAnchor).isActive = true
        refreshAdvanced()

        startLiveTick()
    }

    /// Per-second tick to keep the elapsed time accurate while recording.
    /// `.common` mode so the tile keeps updating when the window isn't
    /// key (e.g. the user clicks into another app with Settings still
    /// visible). `Timer.scheduledTimer` would install on `.default` only.
    /// Started by `build()` (every window open builds a fresh pane) and
    /// stopped from `windowWillClose` — same lifecycle as the sidebar tick.
    /// Relying on `deinit` alone left it running (with its per-second
    /// permission checks) forever after the first Settings open, because the
    /// pane object can outlive the window.
    func startLiveTick() {
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshLiveStatus(self.engineState())
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopLiveTick() {
        timer?.invalidate()
        timer = nil
    }

    func refreshPermissions() {
        rebuildPermissions()
    }

    private func rebuildPermissions() {
        permsContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let p = PermissionsState.current
        if p.bundleIdMismatch {
            let card = WarningCard(title: "These permissions won't stick",
                                   body: "You launched Ghostie from the command line, not from /Applications/Ghostie.app. macOS keeps permissions per app, so anything you grant here won't apply to the installed app. Quit, then open Ghostie from /Applications.")
            permsContainer.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: permsContainer.widthAnchor).isActive = true
        } else if !p.allRequiredGranted {
            let banner = PermissionsBanner(state: p)
            permsContainer.addArrangedSubview(banner)
            banner.widthAnchor.constraint(equalTo: permsContainer.widthAnchor).isActive = true
        } else {
            let card = GroupCard(title: "System Access")
            card.addRow(RowBuilder.row(
                label: "Microphone",
                sub: "Lets Ghostie capture your voice during a Teams call.",
                leadingSymbol: "mic.fill", leadingTint: Theme.danger,
                control: StatusBadgeView(kind: .ok, label: "Granted")))
            card.addRow(RowBuilder.row(
                label: "Screen Recording",
                sub: "Used to capture the other participants — Ghostie only keeps the audio, never the picture.",
                leadingSymbol: "display", leadingTint: Theme.info,
                control: StatusBadgeView(kind: .ok, label: "Granted")))
            card.addRow(RowBuilder.row(
                label: "Accessibility",
                sub: p.ax
                    ? "Helps Ghostie tell a real Teams meeting apart from the app just being open. Optional."
                    : "Optional — helps Ghostie spot a real meeting window. Calls still get recorded without it.",
                leadingSymbol: "figure.stand", leadingTint: NSColor.systemGray,
                control: StatusBadgeView(kind: p.ax ? .ok : .muted,
                                         label: p.ax ? "Granted" : "Skipped")),
                        last: true)
            permsContainer.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: permsContainer.widthAnchor).isActive = true
        }
    }

    func refreshLiveStatus(_ state: EngineState) {
        liveStatusRow?.apply(state: state)
    }

    private func refreshAdvanced() {
        advancedContainer.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard Disclosure.isOn else { return }
        let card = GroupCard(title: "Detection · Advanced")
        // Parens matter — `??` binds looser than `+`, so the previous form
        // (`first ?? "..." + suffix`) silently dropped the "+N" tail and only
        // showed the fallback string with the count when `first` was nil.
        let primary = cfg.triggerBundleIds.first ?? "com.microsoft.teams"
        let extras = cfg.triggerBundleIds.count > 1
            ? " +\(cfg.triggerBundleIds.count - 1)"
            : ""
        card.addRow(RowBuilder.row(
            label: "Apps that count as Teams",
            sub: "Ghostie only treats microphone activity as a call when one of these apps is running.",
            control: NSTextField(labelWithString: primary + extras)
                .styledAsMono()), last: true)
        advancedContainer.addArrangedSubview(card)
        card.widthAnchor.constraint(equalTo: advancedContainer.widthAnchor).isActive = true
    }

    private func buildToggleRow(label: String, sub: String, on: Bool,
                                onChange: @escaping (Bool) -> Void) -> NSView {
        let toggle = NSSwitch()
        toggle.controlSize = .small
        toggle.state = on ? .on : .off
        toggle.translatesAutoresizingMaskIntoConstraints = false
        let target = ToggleTarget { onChange(toggle.state == .on) }
        toggle.target = target
        toggle.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(toggle, &ToggleTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        return RowBuilder.row(label: label, sub: sub, control: toggle)
    }

    private func buildStepperRow(label: String, sub: String, initial: Int,
                                 range: ClosedRange<Int>, suffix: String,
                                 onChange: @escaping (Int) -> Void,
                                 last: Bool = false) -> NSView {
        let tf = NSTextField()
        tf.stringValue = String(initial)
        tf.alignment = .right
        tf.font = .systemFont(ofSize: 12.5)
        tf.bezelStyle = .roundedBezel
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.widthAnchor.constraint(equalToConstant: 60).isActive = true
        let stepper = NSStepper()
        stepper.minValue = Double(range.lowerBound)
        stepper.maxValue = Double(range.upperBound)
        stepper.integerValue = initial
        stepper.translatesAutoresizingMaskIntoConstraints = false
        let suffixL = NSTextField(labelWithString: suffix)
        suffixL.font = .systemFont(ofSize: 12)
        suffixL.textColor = Theme.text2
        let target = StepperTarget(tf: tf, stepper: stepper) { v in onChange(v) }
        stepper.target = target
        stepper.action = #selector(StepperTarget.stepperChanged)
        tf.target = target
        tf.action = #selector(StepperTarget.textChanged)
        tf.delegate = target
        objc_setAssociatedObject(stepper, &StepperTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        let h = NSStackView(views: [tf, stepper, suffixL])
        h.orientation = .horizontal
        h.spacing = 6
        h.alignment = .firstBaseline
        return RowBuilder.row(label: label, sub: sub, control: h)
    }
}

private final class StepperTarget: NSObject, NSTextFieldDelegate {
    static var key: UInt8 = 0
    let tf: NSTextField
    let stepper: NSStepper
    let onChange: (Int) -> Void
    init(tf: NSTextField, stepper: NSStepper, onChange: @escaping (Int) -> Void) {
        self.tf = tf; self.stepper = stepper; self.onChange = onChange
    }
    @objc func stepperChanged() {
        tf.integerValue = stepper.integerValue
        onChange(stepper.integerValue)
    }
    @objc func textChanged() {
        if let v = Int(tf.stringValue) {
            let clamped = max(Int(stepper.minValue), min(Int(stepper.maxValue), v))
            stepper.integerValue = clamped
            tf.integerValue = clamped
            onChange(clamped)
        }
    }
    func controlTextDidEndEditing(_ obj: Notification) { textChanged() }
}

// MARK: - Live status row

private final class LiveStatusRow: NSView {
    private let tile = NSView()
    private let symbol = NSImageView()
    private var pulseLayer: CAShapeLayer?
    /// Last tile color, kept so a light/dark switch can re-resolve the
    /// `cgColor` snapshot — the tile color otherwise only refreshes on the
    /// next engine state change.
    private var tileBg: NSColor = Theme.chipBg
    private func setTileBg(_ c: NSColor) {
        tileBg = c
        tile.layer?.backgroundColor = themedCG(c)
    }
    private let title = NSTextField(labelWithString: "")
    private let timeMono = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let button: StyledButton
    private let onPause: () -> Void

    init(onPause: @escaping () -> Void) {
        self.onPause = onPause
        self.button = StyledButton(title: "Pause listening", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        tile.translatesAutoresizingMaskIntoConstraints = false
        tile.wantsLayer = true
        tile.layer?.cornerRadius = 10
        symbol.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(symbol)
        addSubview(tile)

        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = Theme.text
        title.translatesAutoresizingMaskIntoConstraints = false

        timeMono.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        timeMono.textColor = Theme.text2
        timeMono.translatesAutoresizingMaskIntoConstraints = false

        detail.font = .systemFont(ofSize: 12)
        detail.textColor = Theme.text2
        detail.translatesAutoresizingMaskIntoConstraints = false

        let titleLine = NSStackView(views: [title, timeMono])
        titleLine.orientation = .horizontal
        titleLine.alignment = .firstBaseline
        titleLine.spacing = 10

        let stack = NSStackView(views: [titleLine, detail])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        let pauseTarget = ActionTarget { [weak self] in self?.onPause() }
        button.target = pauseTarget
        button.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(button, &ActionTarget.key, pauseTarget, .OBJC_ASSOCIATION_RETAIN)
        addSubview(button)

        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            tile.widthAnchor.constraint(equalToConstant: 42),
            tile.heightAnchor.constraint(equalToConstant: 42),
            symbol.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            symbol.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 20),
            symbol.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: 14),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -12),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
            topAnchor.constraint(equalTo: tile.topAnchor, constant: -14),
            bottomAnchor.constraint(equalTo: tile.bottomAnchor, constant: 14)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func apply(state: EngineState) {
        if case .recording = state { startPulse() } else { stopPulse() }
        switch state {
        case .recording(let since):
            setTileBg(Theme.dangerSoft)
            symbol.image = NSImage(systemSymbolName: "record.circle",
                                   accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            symbol.contentTintColor = Theme.danger
            title.stringValue = "Recording"
            let secs = Int(Date().timeIntervalSince(since))
            timeMono.stringValue = String(format: "%02d:%02d", secs / 60, secs % 60)
            timeMono.isHidden = false
            detail.stringValue = "A Teams call is in progress."
            button.title = "Pause listening"
            button.kind = .ghost
        case .watching:
            setTileBg(Theme.okSoft)
            symbol.image = NSImage(systemSymbolName: "mic",
                                   accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            symbol.contentTintColor = Theme.ok
            title.stringValue = "Watching for calls"
            timeMono.stringValue = ""
            timeMono.isHidden = true
            detail.stringValue = "Idle. Ghostie will wake up the next time Teams starts using the mic."
            button.title = "Pause listening"
            button.kind = .ghost
        case .processing:
            setTileBg(Theme.infoSoft)
            symbol.image = NSImage(systemSymbolName: "sparkles",
                                   accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            symbol.contentTintColor = Theme.info
            title.stringValue = "Writing the note"
            timeMono.stringValue = ""
            timeMono.isHidden = true
            detail.stringValue = "Claude is reading the transcript and pulling out the highlights."
            button.title = "Pause listening"
            button.kind = .ghost
        case .paused:
            setTileBg(Theme.chipBg)
            symbol.image = NSImage(systemSymbolName: "pause.fill",
                                   accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
            symbol.contentTintColor = Theme.text2
            title.stringValue = "Paused"
            timeMono.stringValue = ""
            timeMono.isHidden = true
            detail.stringValue = "Ghostie isn't watching for calls right now."
            button.title = "Resume listening"
            button.kind = .primary
        }
    }

    /// Single ring under the symbol that scales out and fades — the recording
    /// pulse from the design spec. Removed on every non-recording state.
    private func startPulse() {
        guard pulseLayer == nil, tile.layer != nil else { return }
        let ring = CAShapeLayer()
        ring.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 12, height: 12), transform: nil)
        ring.fillColor = NSColor.clear.cgColor
        ring.strokeColor = Theme.danger.cgColor
        ring.lineWidth = 1.5
        ring.bounds = CGRect(x: 0, y: 0, width: 12, height: 12)
        ring.position = CGPoint(x: 21, y: 21)
        tile.layer?.addSublayer(ring)
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 1.0
        scale.toValue = 2.8
        scale.duration = 1.6
        scale.repeatCount = .infinity
        scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let op = CABasicAnimation(keyPath: "opacity")
        op.fromValue = 0.5
        op.toValue = 0.0
        op.duration = 1.6
        op.repeatCount = .infinity
        ring.add(scale, forKey: "scale")
        ring.add(op, forKey: "opacity")
        pulseLayer = ring
    }
    private func stopPulse() {
        pulseLayer?.removeAllAnimations()
        pulseLayer?.removeFromSuperlayer()
        pulseLayer = nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        tile.layer?.backgroundColor = themedCG(tileBg)
    }
}

private final class WarningCard: NSView {
    init(title: String, body: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.borderWidth = 0.5
        layer?.borderColor = themedCG(Theme.warn)
        layer?.backgroundColor = themedCG(Theme.warnSoft)
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 13, weight: .semibold)
        t.textColor = Theme.text
        let b = NSTextField(wrappingLabelWithString: body)
        b.font = .systemFont(ofSize: 12)
        b.textColor = Theme.text2
        b.preferredMaxLayoutWidth = 600
        let stack = NSStackView(views: [t, b])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.borderColor = themedCG(Theme.warn)
        layer?.backgroundColor = themedCG(Theme.warnSoft)
    }
}
