import AppKit

/// The little ghost in the sidebar brand row. Solid black silhouette from
/// `GhostIcon.bodyPath`, two white pupils that follow the mouse pointer
/// anywhere in the Settings window via a local event monitor.
private final class GhostBrandView: NSView {

    private var lookOffset = NSPoint.zero
    private var monitor: Any?
    /// Pupil offset is clamped to a small radius so the eye stays cleanly
    /// inside the ghost's face even when the cursor is in the far corner.
    private static let maxOffset: CGFloat = 1.8

    override init(frame: NSRect) {
        super.init(frame: frame)
        // No layer-backed background — the previous indigo tile is gone, so
        // the ghost draws straight onto the sidebar's vibrancy.
        // Watch every mouse-moved event in the app while this view is alive.
        // `addLocalMonitorForEvents` runs the callback before the event hits
        // the responder chain, which means we don't need a tracking area on
        // the whole window. Re-render on every move.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] event in
            self?.updateGaze(toWindowPoint: event.locationInWindow)
            return event
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    deinit { if let m = monitor { NSEvent.removeMonitor(m) } }

    private func updateGaze(toWindowPoint p: NSPoint) {
        guard window != nil else { return }
        let pInView = convert(p, from: nil)
        let center = NSPoint(x: bounds.midX, y: bounds.midY + bounds.height * 0.10)
        let dx = pInView.x - center.x
        let dy = pInView.y - center.y
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > 0 else { lookOffset = .zero; needsDisplay = true; return }
        // Normalize direction and pin to max offset — the eyes always commit
        // to looking at the cursor, near or far.
        let scale = Self.maxOffset / dist
        lookOffset = NSPoint(x: dx * scale, y: dy * scale)
        needsDisplay = true
    }

    override func draw(_ rect: NSRect) {
        // Black ghost body, no backdrop. The full view is the ghost.
        let face = bounds
        let body = GhostIcon.bodyPath(in: face)
        NSColor.labelColor.setFill()   // black in light mode, white in dark
        body.fill()

        // Sclera (the white of the eye) sits at a fixed position on the
        // ghost's face. The iris is a smaller, darker oval inside the sclera
        // that translates with `lookOffset` so the gaze follows the cursor.
        let (sL, _, sR, _) = GhostIcon.eyeRects(in: face)
        let scleraW = face.width * 0.22
        let scleraH = face.width * 0.28
        let irisW = face.width * 0.11
        let irisH = face.width * 0.14

        NSColor.white.setFill()
        let leftSclera = NSRect(x: sL.midX - scleraW / 2,
                                 y: sL.midY - scleraH / 2,
                                 width: scleraW, height: scleraH)
        let rightSclera = NSRect(x: sR.midX - scleraW / 2,
                                  y: sR.midY - scleraH / 2,
                                  width: scleraW, height: scleraH)
        NSBezierPath(ovalIn: leftSclera).fill()
        NSBezierPath(ovalIn: rightSclera).fill()

        // Black iris on the white sclera — monochrome by design. Stays
        // black in both light and dark mode (the sclera is always white,
        // so a black iris reads correctly either way).
        NSColor.black.setFill()
        let leftIris = NSRect(x: sL.midX - irisW / 2 + lookOffset.x,
                              y: sL.midY - irisH / 2 + lookOffset.y,
                              width: irisW, height: irisH)
        let rightIris = NSRect(x: sR.midX - irisW / 2 + lookOffset.x,
                               y: sR.midY - irisH / 2 + lookOffset.y,
                               width: irisW, height: irisH)
        NSBezierPath(ovalIn: leftIris).fill()
        NSBezierPath(ovalIn: rightIris).fill()
    }
}


// MARK: - Sidebar

final class Sidebar: NSView {

    private let paneOrder: [PaneId]
    private let paneBottom: [PaneId]
    private let onSelect: (PaneId) -> Void

    private var itemRows: [PaneId: SidebarItem] = [:]
    private let statusDot = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    /// Last status-dot color, kept so a light/dark switch can re-resolve the
    /// `cgColor` snapshot without waiting for the next engine state change.
    private var statusDotColor: NSColor = Theme.text3
    private weak var engine: Engine?

    init(paneOrder: [PaneId], paneBottom: [PaneId], initialPane: PaneId,
         engine: Engine?, onSelect: @escaping (PaneId) -> Void) {
        self.paneOrder = paneOrder
        self.paneBottom = paneBottom
        self.engine = engine
        self.onSelect = onSelect
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = themedCG(Theme.sidebarBg)
        build(selecting: initialPane)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = themedCG(Theme.sidebarBg)
        statusDot.layer?.backgroundColor = themedCG(statusDotColor)
    }

    private func build(selecting initial: PaneId) {
        // Top drag region — height of the traffic-light area.
        let dragRegion = NSView()
        dragRegion.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragRegion)

        // Brand row — the little ghost in the sidebar, with eyes that
        // follow the mouse around the Settings window.
        let brand = NSView()
        brand.translatesAutoresizingMaskIntoConstraints = false
        let logo = GhostBrandView()
        logo.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Ghostie")
        title.font = .systemFont(ofSize: 13.5, weight: .bold)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.wantsLayer = true
        statusDot.layer?.cornerRadius = 3

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.lineBreakMode = .byTruncatingTail

        let titleStack = NSStackView(views: [title])
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 1
        titleStack.translatesAutoresizingMaskIntoConstraints = false

        let statusLine = NSStackView(views: [statusDot, statusLabel])
        statusLine.orientation = .horizontal
        statusLine.alignment = .centerY
        statusLine.spacing = 4
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        titleStack.addArrangedSubview(statusLine)

        brand.addSubview(logo)
        brand.addSubview(titleStack)
        addSubview(brand)

        NSLayoutConstraint.activate([
            dragRegion.topAnchor.constraint(equalTo: topAnchor),
            dragRegion.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragRegion.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragRegion.heightAnchor.constraint(equalToConstant: 38),

            brand.topAnchor.constraint(equalTo: dragRegion.bottomAnchor, constant: 4),
            brand.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            brand.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),

            logo.leadingAnchor.constraint(equalTo: brand.leadingAnchor),
            logo.topAnchor.constraint(equalTo: brand.topAnchor),
            logo.widthAnchor.constraint(equalToConstant: 38),
            logo.heightAnchor.constraint(equalToConstant: 38),

            titleStack.leadingAnchor.constraint(equalTo: logo.trailingAnchor, constant: 10),
            titleStack.centerYAnchor.constraint(equalTo: logo.centerYAnchor),
            titleStack.trailingAnchor.constraint(equalTo: brand.trailingAnchor),

            statusDot.widthAnchor.constraint(equalToConstant: 6),
            statusDot.heightAnchor.constraint(equalToConstant: 6),

            brand.bottomAnchor.constraint(equalTo: logo.bottomAnchor)
        ])

        // Nav list.
        let nav = NSStackView()
        nav.orientation = .vertical
        nav.alignment = .leading
        nav.spacing = 1
        nav.translatesAutoresizingMaskIntoConstraints = false

        addSubview(nav)
        for id in paneOrder {
            let item = SidebarItem(id: id, onClick: { [weak self] in self?.onSelect($0) })
            nav.addArrangedSubview(item)
            item.leadingAnchor.constraint(equalTo: nav.leadingAnchor).isActive = true
            item.trailingAnchor.constraint(equalTo: nav.trailingAnchor).isActive = true
            itemRows[id] = item
        }
        let powerUser = NSTextField(labelWithString: "POWER USER")
        powerUser.font = .systemFont(ofSize: 10, weight: .semibold)
        powerUser.textColor = .tertiaryLabelColor
        let powerWrap = NSView()
        powerWrap.translatesAutoresizingMaskIntoConstraints = false
        powerWrap.addSubview(powerUser)
        powerUser.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            powerUser.leadingAnchor.constraint(equalTo: powerWrap.leadingAnchor, constant: 4),
            powerUser.topAnchor.constraint(equalTo: powerWrap.topAnchor, constant: 18),
            powerUser.bottomAnchor.constraint(equalTo: powerWrap.bottomAnchor, constant: -4),
            powerUser.trailingAnchor.constraint(lessThanOrEqualTo: powerWrap.trailingAnchor)
        ])
        nav.addArrangedSubview(powerWrap)
        powerWrap.leadingAnchor.constraint(equalTo: nav.leadingAnchor).isActive = true
        powerWrap.trailingAnchor.constraint(equalTo: nav.trailingAnchor).isActive = true
        for id in paneBottom {
            let item = SidebarItem(id: id, onClick: { [weak self] in self?.onSelect($0) })
            nav.addArrangedSubview(item)
            item.leadingAnchor.constraint(equalTo: nav.leadingAnchor).isActive = true
            item.trailingAnchor.constraint(equalTo: nav.trailingAnchor).isActive = true
            itemRows[id] = item
        }

        NSLayoutConstraint.activate([
            nav.topAnchor.constraint(equalTo: brand.bottomAnchor, constant: 14),
            nav.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            nav.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        ])

        // Global Advanced toggle — bottom-left. One switch covers every pane;
        // each pane listens on `Disclosure.didChange` and re-renders its
        // advanced section. Tap target spans label + switch so a click on
        // either flips state.
        let advLabel = NSTextField(labelWithString: "Advanced")
        advLabel.font = .systemFont(ofSize: 12, weight: .medium)
        advLabel.textColor = .secondaryLabelColor
        advLabel.translatesAutoresizingMaskIntoConstraints = false

        let advSwitch = NSSwitch()
        advSwitch.controlSize = .mini
        advSwitch.state = Disclosure.isOn ? .on : .off
        advSwitch.translatesAutoresizingMaskIntoConstraints = false
        let advTarget = ToggleTarget { Disclosure.isOn = (advSwitch.state == .on) }
        advSwitch.target = advTarget
        advSwitch.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(advSwitch, &ToggleTarget.key, advTarget, .OBJC_ASSOCIATION_RETAIN)

        let advRow = NSView()
        advRow.translatesAutoresizingMaskIntoConstraints = false
        advRow.addSubview(advLabel)
        advRow.addSubview(advSwitch)
        // Clicking the label flips the switch — easier target than the
        // (mini) switch knob alone. Held strongly via objc_setAssociatedObject
        // since `NSGestureRecognizer.target` is weak.
        let labelTarget = ActionTarget {
            Disclosure.toggle()
            advSwitch.state = Disclosure.isOn ? .on : .off
        }
        let labelClick = NSClickGestureRecognizer(
            target: labelTarget, action: #selector(ActionTarget.fire))
        advLabel.addGestureRecognizer(labelClick)
        objc_setAssociatedObject(advLabel, &ActionTarget.key, labelTarget,
                                 .OBJC_ASSOCIATION_RETAIN)
        addSubview(advRow)

        NSLayoutConstraint.activate([
            advRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            advRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            advRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            advRow.heightAnchor.constraint(equalToConstant: 22),
            advLabel.leadingAnchor.constraint(equalTo: advRow.leadingAnchor),
            advLabel.centerYAnchor.constraint(equalTo: advRow.centerYAnchor),
            advSwitch.trailingAnchor.constraint(equalTo: advRow.trailingAnchor),
            advSwitch.centerYAnchor.constraint(equalTo: advRow.centerYAnchor)
        ])

        widthAnchor.constraint(equalToConstant: 220).isActive = true
        setSelected(initial)
        refreshStatus(engine?.state ?? .paused, perms: PermissionsState.current)
    }

    func setSelected(_ id: PaneId) {
        for (k, v) in itemRows { v.setActive(k == id) }
    }

    func refreshStatus(_ state: EngineState, perms: PermissionsState) {
        switch state {
        case .paused:
            statusDotColor = Theme.text3
            statusLabel.stringValue = "Paused"
        case .watching:
            statusDotColor = Theme.ok
            statusLabel.stringValue = "Watching"
        case .recording(let since):
            statusDotColor = Theme.danger
            let secs = Int(Date().timeIntervalSince(since))
            statusLabel.stringValue = String(format: "Recording · %02d:%02d", secs / 60, secs % 60)
        case .processing:
            statusDotColor = Theme.info
            statusLabel.stringValue = "Summarizing"
        }
        statusDot.layer?.backgroundColor = themedCG(statusDotColor)
        itemRows[.listening]?.setBadge(perms.allRequiredGranted ? nil : .warn)
    }
}

private final class SidebarItem: NSView {
    private let id: PaneId
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var badge = NSView()
    private let onClick: (PaneId) -> Void
    private var active = false
    private var trackingArea: NSTrackingArea?

    init(id: PaneId, onClick: @escaping (PaneId) -> Void) {
        self.id = id
        self.onClick = onClick
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 6

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: id.systemSymbol,
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        // System semantic colors instead of Theme.text2/Theme.text. The custom
        // dynamic NSColor providers (NSColor(name: nil) { ap in ... }) were
        // freezing at light-mode resolution inside layer-backed sidebar items
        // and never refreshing — `.secondaryLabelColor` / `.labelColor` are
        // managed by AppKit and update reliably on appearance changes.
        icon.contentTintColor = .secondaryLabelColor

        label.stringValue = id.title
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false

        badge.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(label)
        addSubview(badge)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -4)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func setActive(_ on: Bool) {
        active = on
        applyTheme()
    }

    /// Re-resolve every dynamic color we depend on. Layer-backed views capture
    /// `cgColor` snapshots that don't track appearance changes, and AppKit
    /// occasionally caches `NSTextField`/`NSImageView` tints set before the
    /// window's effective appearance flipped to `.darkAqua`. Calling this on
    /// both `setActive(_:)` and `viewDidChangeEffectiveAppearance` keeps the
    /// sidebar legible whether the user toggles dark mode at launch or
    /// mid-session.
    private func applyTheme() {
        layer?.backgroundColor = active ? themedCG(Theme.selectedItem) : NSColor.clear.cgColor
        icon.contentTintColor = active ? Theme.accent : .secondaryLabelColor
        label.textColor = .labelColor
        label.font = .systemFont(ofSize: 13, weight: active ? .semibold : .medium)
        label.needsDisplay = true
        icon.needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTheme()
    }

    enum BadgeKind { case warn }
    func setBadge(_ kind: BadgeKind?) {
        badge.subviews.forEach { $0.removeFromSuperview() }
        guard let kind else { return }
        let dot = ThemedLayerView()
        dot.themeApply = { $0.layer?.backgroundColor = (kind == .warn ? Theme.warn : Theme.danger).cgColor }
        dot.layer?.cornerRadius = 4
        badge.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            badge.widthAnchor.constraint(equalToConstant: 12),
            badge.heightAnchor.constraint(equalToConstant: 12)
        ])
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
    override func mouseEntered(with event: NSEvent) {
        if !active { layer?.backgroundColor = themedCG(Theme.chipBg) }
    }
    override func mouseExited(with event: NSEvent) {
        if !active { layer?.backgroundColor = NSColor.clear.cgColor }
    }
    override func mouseDown(with event: NSEvent) {
        onClick(id)
    }
}
