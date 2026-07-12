import AppKit
import QuartzCore

/// Single global "Show advanced" flag. Replaced the per-pane disclosures —
/// having one switch per pane meant the user had to flip it five times to see
/// every advanced row. One switch in the sidebar covers all panes; the panes
/// listen on `didChange` and re-show their advanced cards.
enum Disclosure {
    static let key = "ghostie.advanced"
    static let didChange = Notification.Name("ghostie.disclosure.didChange")
    static var isOn: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }
    static func toggle() { isOn.toggle() }
}

// MARK: - Primitives

extension NSView {
    /// Resolve a (possibly dynamic light/dark) `NSColor` to a `CGColor` in
    /// *this view's* current effective appearance.
    ///
    /// Plain `NSColor.cgColor` snapshots whatever the ambient drawing
    /// appearance happens to be at the moment of the call. That ambient value
    /// is correct at launch but is **not** refreshed for you inside
    /// `viewDidChangeEffectiveAppearance` — so a layer background assigned via
    /// `Theme.x.cgColor` freezes at whatever mode the window first opened in
    /// and never follows a system dark/light switch. Dynamic colors used
    /// *directly* (text colors, image tints, `NSScrollView.backgroundColor`)
    /// are fine because AppKit re-resolves those itself; only the `cgColor`
    /// snapshots on `CALayer`s need this. Resolving inside the view's own
    /// `effectiveAppearance` makes the snapshot track the switch.
    func themedCG(_ color: NSColor) -> CGColor {
        var cg = color.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { cg = color.cgColor }
        return cg
    }
}

/// A layer-backed `NSView` whose layer colors are re-resolved on every
/// light/dark switch. A naked `NSView()` can't react to appearance changes;
/// this one re-runs `themeApply` — both when first assigned and on every
/// `viewDidChangeEffectiveAppearance` — with the view's current appearance
/// installed as the drawing appearance, so plain `.cgColor` inside it resolves
/// correctly.
final class ThemedLayerView: NSView {
    var themeApply: ((ThemedLayerView) -> Void)? { didSet { refreshTheme() } }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshTheme()
    }
    private func refreshTheme() {
        guard let themeApply else { return }
        effectiveAppearance.performAsCurrentDrawingAppearance { themeApply(self) }
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = themedCG(Theme.contentBg)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = themedCG(Theme.contentBg)
    }
}


/// Card with a 0.5 pt border and 10 pt corner radius. Holds rows + dividers.
final class GroupCard: NSView {
    private let stack = NSStackView()
    private let titleLabel = NSTextField(labelWithString: "")
    init(title: String? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if let title {
            titleLabel.stringValue = title.uppercased()
            titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            titleLabel.textColor = Theme.text2
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
        }
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.wantsLayer = true
        stack.layer?.backgroundColor = themedCG(Theme.cardBg)
        stack.layer?.cornerRadius = 10
        stack.layer?.borderWidth = 0.5
        stack.layer?.borderColor = themedCG(Theme.cardBorder)
        stack.layer?.masksToBounds = true
        stack.edgeInsets = .init()

        addSubview(stack)
        var consts: [NSLayoutConstraint] = []
        if title != nil {
            addSubview(titleLabel)
            consts += [
                titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
                titleLabel.topAnchor.constraint(equalTo: topAnchor),
                stack.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7)
            ]
        } else {
            consts += [stack.topAnchor.constraint(equalTo: topAnchor)]
        }
        consts += [
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ]
        NSLayoutConstraint.activate(consts)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        stack.layer?.backgroundColor = themedCG(Theme.cardBg)
        stack.layer?.borderColor = themedCG(Theme.cardBorder)
    }

    /// Remove every row (and divider) so the card can be rebuilt in place —
    /// used by the catalog-driven Models card when the user adds a model.
    func clearRows() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
    }

    func addRow(_ row: NSView, last: Bool = false) {
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.leadingAnchor.constraint(equalTo: stack.leadingAnchor).isActive = true
        row.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
        if !last {
            let div = DividerView()
            stack.addArrangedSubview(div)
            div.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 14).isActive = true
            div.trailingAnchor.constraint(equalTo: stack.trailingAnchor).isActive = true
            div.heightAnchor.constraint(equalToConstant: 0.5).isActive = true
        }
    }
}

final class DividerView: NSView {
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = themedCG(Theme.rowDivider)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = themedCG(Theme.rowDivider)
    }
}

final class PageHeaderView: NSView {
    init(title: String, subtitle: String?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let t = NSTextField(labelWithString: title)
        t.font = .systemFont(ofSize: 22, weight: .bold)
        t.textColor = Theme.text
        t.translatesAutoresizingMaskIntoConstraints = false
        addSubview(t)
        var consts: [NSLayoutConstraint] = [
            t.topAnchor.constraint(equalTo: topAnchor),
            t.leadingAnchor.constraint(equalTo: leadingAnchor),
            t.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor)
        ]
        if let subtitle {
            let s = NSTextField(wrappingLabelWithString: subtitle)
            s.font = .systemFont(ofSize: 12.5)
            s.textColor = Theme.text2
            s.translatesAutoresizingMaskIntoConstraints = false
            s.preferredMaxLayoutWidth = 560
            addSubview(s)
            consts += [
                s.topAnchor.constraint(equalTo: t.bottomAnchor, constant: 3),
                s.leadingAnchor.constraint(equalTo: leadingAnchor),
                s.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
                s.bottomAnchor.constraint(equalTo: bottomAnchor)
            ]
        } else {
            consts += [t.bottomAnchor.constraint(equalTo: bottomAnchor)]
        }
        NSLayoutConstraint.activate(consts)
    }
    required init?(coder: NSCoder) { fatalError() }
}

final class StatusBadgeView: NSView {

    enum Kind { case ok, warn, danger, info, muted, accent }

    private var kind: Kind
    private var label: String
    private let dot = NSView()
    private let text = NSTextField(labelWithString: "")
    private var pulseLayer: CAShapeLayer?

    init(kind: Kind, label: String, pulsing: Bool = false) {
        self.kind = kind
        self.label = label
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 9
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.wantsLayer = true
        text.font = .systemFont(ofSize: 11, weight: .semibold)
        text.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dot)
        addSubview(text)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 6),
            dot.heightAnchor.constraint(equalToConstant: 6),
            text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18)
        ])
        apply()
        if pulsing { startPulse() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(kind: Kind, label: String) {
        self.kind = kind
        self.label = label
        apply()
    }

    private var cachedLabel: String?
    private var cachedKind: Kind?

    private func apply() {
        let (bg, fg) = colors(for: kind)
        layer?.backgroundColor = themedCG(bg)
        dot.layer?.backgroundColor = themedCG(fg)
        dot.layer?.cornerRadius = 3
        // NSTextField redraws on every stringValue/textColor assignment even
        // when the value hasn't changed, which cascades back into our redraw
        // chain — only push when something is actually new.
        if cachedLabel != label {
            cachedLabel = label
            text.stringValue = label
        }
        if cachedKind != kind {
            cachedKind = kind
            text.textColor = fg
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        let (bg, fg) = colors(for: kind)
        layer?.backgroundColor = themedCG(bg)
        dot.layer?.backgroundColor = themedCG(fg)
        text.textColor = fg
    }

    func startPulse() {
        guard pulseLayer == nil else { return }
        let r = CAShapeLayer()
        r.path = CGPath(ellipseIn: CGRect(x: 0, y: 0, width: 6, height: 6), transform: nil)
        let (_, fg) = colors(for: kind)
        r.fillColor = fg.withAlphaComponent(0.5).cgColor
        r.frame = CGRect(x: 0, y: 0, width: 6, height: 6)
        dot.layer?.addSublayer(r)
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
        r.add(scale, forKey: "scale")
        r.add(op, forKey: "opacity")
        pulseLayer = r
    }

    func stopPulse() {
        pulseLayer?.removeAllAnimations()
        pulseLayer?.removeFromSuperlayer()
        pulseLayer = nil
    }

    private func colors(for k: Kind) -> (bg: NSColor, fg: NSColor) {
        switch k {
        case .ok:     return (Theme.okSoft, Theme.ok)
        case .warn:   return (Theme.warnSoft, Theme.warn)
        case .danger: return (Theme.dangerSoft, Theme.danger)
        case .info:   return (Theme.infoSoft, Theme.info)
        case .accent: return (Theme.accentSoft, Theme.accent)
        case .muted:  return (Theme.chipBg, Theme.text2)
        }
    }
}

/// One settings row. Optional leading tinted icon tile, label + sub, trailing
/// control. The control area is a single NSView so callers can drop any control
/// (toggle, segmented control, button, badge) into the same slot.
final class RowBuilder {
    static func row(label: String,
                    sub: String? = nil,
                    leadingSymbol: String? = nil,
                    leadingImage: NSImage? = nil,
                    leadingImageBare: Bool = false,
                    leadingTint: NSColor? = nil,
                    control: NSView? = nil,
                    danger: Bool = false) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        var leading: NSView = row
        var leadingConstant: CGFloat = 14
        // Either an SF Symbol name or a pre-made template image gets the same
        // leading-tile treatment. `leadingImage` wins if both are supplied.
        let symbolImage = leadingSymbol.flatMap {
            NSImage(systemSymbolName: $0, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        }
        if let image = leadingImage ?? symbolImage {
            let tile = ThemedLayerView()
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.image = image
            iv.contentTintColor = leadingTint != nil ? .white : .secondaryLabelColor
            tile.addSubview(iv)
            row.addSubview(tile)

            if leadingImageBare {
                // No tile background, no chrome. The image fills the leading
                // area at its native aspect ratio (height pinned, width
                // proportionally scaled by NSImageView).
                iv.imageScaling = .scaleProportionallyUpOrDown
                iv.imageAlignment = .alignCenter
                NSLayoutConstraint.activate([
                    tile.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                    tile.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    tile.widthAnchor.constraint(equalToConstant: 26),
                    tile.heightAnchor.constraint(equalToConstant: 26),
                    iv.topAnchor.constraint(equalTo: tile.topAnchor),
                    iv.bottomAnchor.constraint(equalTo: tile.bottomAnchor),
                    iv.leadingAnchor.constraint(equalTo: tile.leadingAnchor),
                    iv.trailingAnchor.constraint(equalTo: tile.trailingAnchor)
                ])
            } else {
                tile.themeApply = { $0.layer?.backgroundColor = (leadingTint ?? Theme.chipBg).cgColor }
                tile.layer?.cornerRadius = 6
                NSLayoutConstraint.activate([
                    tile.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                    tile.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                    tile.widthAnchor.constraint(equalToConstant: 26),
                    tile.heightAnchor.constraint(equalToConstant: 26),
                    iv.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
                    iv.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 15),
                    iv.heightAnchor.constraint(equalToConstant: 15)
                ])
            }
            leading = tile
            leadingConstant = 12
        }

        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 13, weight: .medium)
        l.textColor = danger ? Theme.danger : Theme.text
        l.translatesAutoresizingMaskIntoConstraints = false
        l.lineBreakMode = .byTruncatingTail
        row.addSubview(l)

        let labelStack = NSStackView()
        labelStack.orientation = .vertical
        labelStack.alignment = .leading
        labelStack.spacing = 1.5
        labelStack.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(labelStack)
        labelStack.addArrangedSubview(l)
        if let sub {
            let s = NSTextField(wrappingLabelWithString: sub)
            s.font = .systemFont(ofSize: 11.5)
            s.textColor = Theme.text2
            // `wrappingLabelWithString` defaults to `.byWordWrapping`. Leave
            // it alone — overriding to `.byTruncatingTail` was killing the
            // wrap and letting the text run behind the trailing control.
            s.translatesAutoresizingMaskIntoConstraints = false
            s.maximumNumberOfLines = 2
            // Allow the layout solver to shrink the sub freely so it wraps
            // when a wide control (e.g. an NSPopUpButton) occupies the right
            // side of the row.
            s.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            s.setContentHuggingPriority(.defaultLow, for: .horizontal)
            labelStack.addArrangedSubview(s)
            s.widthAnchor.constraint(lessThanOrEqualToConstant: 520).isActive = true
        }
        l.removeFromSuperview()
        labelStack.insertArrangedSubview(l, at: 0)

        var constraints: [NSLayoutConstraint] = []
        if leading !== row {
            // A leading tile (icon) was added — anchor the label stack to it.
            constraints += [
                labelStack.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: leadingConstant)
            ]
        } else {
            constraints += [
                labelStack.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14)
            ]
        }
        constraints += [
            labelStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 11),
            labelStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -11),
        ]

        if let control {
            control.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(control)
            constraints += [
                control.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
                control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
                control.leadingAnchor.constraint(greaterThanOrEqualTo: labelStack.trailingAnchor, constant: 12)
            ]
        } else {
            constraints += [labelStack.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -14)]
        }
        NSLayoutConstraint.activate(constraints)
        return row
    }

    static func numberInput(value: String, suffix: String?, width: CGFloat = 64,
                            target: AnyObject?, action: Selector?) -> NSView {
        let tf = NSTextField()
        tf.stringValue = value
        tf.alignment = .right
        tf.font = .systemFont(ofSize: 12.5)
        tf.bezelStyle = .roundedBezel
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.target = target
        tf.action = action
        tf.widthAnchor.constraint(equalToConstant: width).isActive = true
        if let suffix {
            let s = NSTextField(labelWithString: suffix)
            s.font = .systemFont(ofSize: 12)
            s.textColor = Theme.text2
            let h = NSStackView(views: [tf, s])
            h.orientation = .horizontal
            h.spacing = 6
            h.alignment = .firstBaseline
            h.translatesAutoresizingMaskIntoConstraints = false
            return h
        }
        return tf
    }

    static func button(_ title: String,
                       kind: ButtonKind = .secondary,
                       target: AnyObject?, action: Selector?) -> NSButton {
        let b = StyledButton(title: title, target: target, action: action)
        b.kind = kind
        return b
    }
}

enum ButtonKind { case primary, secondary, danger, ghost }

/// A flat NSButton that uses a layer-backed background so it can match the
/// design tokens regardless of the running macOS theme. Stays an `NSButton`
/// underneath so target/action wiring and keyboard handling are unchanged.
final class StyledButton: NSButton {

    var kind: ButtonKind = .secondary { didSet { restyle() } }

    override var title: String {
        // Once attributedTitle is set, NSButton stops honouring `title` for
        // display — so a `button.title = "Resume"` swap from outside would
        // otherwise leave the old attributed string on screen. Hook the setter
        // and rebuild the attributed title whenever the underlying title moves.
        didSet { restyle() }
    }

    init(title: String, target: AnyObject?, action: Selector?) {
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        self.bezelStyle = .regularSquare
        self.isBordered = false
        self.translatesAutoresizingMaskIntoConstraints = false
        self.wantsLayer = true
        self.layer?.cornerRadius = 6
        self.layer?.borderWidth = 0.5
        self.font = .systemFont(ofSize: 12, weight: .medium)
        self.heightAnchor.constraint(greaterThanOrEqualToConstant: 24).isActive = true
        restyle()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        let s = super.intrinsicContentSize
        return NSSize(width: s.width + 22, height: max(s.height, 24))
    }

    private var cachedTitle: String = ""
    private var cachedFg: NSColor?

    /// Recompute the layer colours + attributed title. Idempotent: skips the
    /// attributed-title rebuild when the title and resolved foreground haven't
    /// changed, otherwise this would recurse forever — setting `attributedTitle`
    /// inside `updateLayer()` marks the button for redisplay, which re-fires
    /// `updateLayer()`, allocating a new NSAttributedString each loop until the
    /// process eats all available memory. Layer colors go through `themedCG`
    /// so they re-resolve correctly when called from
    /// `viewDidChangeEffectiveAppearance` on a light/dark switch.
    private func restyle() {
        let (bg, fg, border) = colors()
        layer?.backgroundColor = themedCG(bg)
        layer?.borderColor = themedCG(border)
        if cachedTitle != title || cachedFg != fg {
            cachedTitle = title
            cachedFg = fg
            attributedTitle = NSAttributedString(
                string: title,
                attributes: [
                    .foregroundColor: fg,
                    .font: font ?? .systemFont(ofSize: 12, weight: .medium)
                ])
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    private func colors() -> (NSColor, NSColor, NSColor) {
        switch kind {
        case .primary:   return (Theme.accent, .white, .clear)
        case .secondary: return (Theme.chipBg, Theme.text, .clear)
        case .ghost:     return (.clear, Theme.text, Theme.inputBorder)
        case .danger:    return (.clear, Theme.danger, Theme.danger)
        }
    }
}

final class ToggleTarget {
    static var key: UInt8 = 0
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

final class ActionTarget {
    static var key: UInt8 = 0
    let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func fire() { block() }
}

// MARK: - Misc helpers

extension NSTextField {
    /// Style a static label with the monospace font used for paths / sizes.
    func styledAsMono() -> NSTextField {
        font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textColor = Theme.text2
        return self
    }
}
