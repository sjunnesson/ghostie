import AppKit
import AVFoundation

// MARK: - Permissions state

struct PermissionsState {
    let mic: Bool
    let micDenied: Bool
    let screen: Bool
    let ax: Bool

    var allRequiredGranted: Bool { mic && screen }
    var allGranted: Bool { mic && screen && ax }
    var bundleIdMismatch: Bool {
        // CLI builds carry a different code identity than the installed .app;
        // a grant against the CLI doesn't transfer. Surface it as if the
        // perms were missing so the banner explains the situation.
        !CommandLine.arguments[0].contains(".app/Contents/MacOS/")
    }

    static var current: PermissionsState {
        let micAuth = AVCaptureDevice.authorizationStatus(for: .audio)
        return PermissionsState(
            mic: micAuth == .authorized,
            micDenied: micAuth == .denied,
            screen: CGPreflightScreenCaptureAccess(),
            ax: AXIsProcessTrusted())
    }
}

// MARK: - Permissions banner

final class PermissionsBanner: NSView {
    /// Re-resolves every layer `cgColor` in the banner — its own border/fill
    /// plus the warning badge and the inner card — on a light/dark switch.
    private var themeRefresh: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { themeRefresh?() }
    }

    init(state: PermissionsState) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        layer?.borderColor = themedCG(Theme.warn)
        layer?.backgroundColor = themedCG(Theme.warnSoft)
        layer?.masksToBounds = true

        // Header.
        let header = NSView()
        header.translatesAutoresizingMaskIntoConstraints = false
        let badge = NSView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 13
        badge.layer?.backgroundColor = themedCG(Theme.warn)
        let bang = NSImageView()
        bang.translatesAutoresizingMaskIntoConstraints = false
        bang.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                             accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        bang.contentTintColor = .white
        badge.addSubview(bang)
        let title = NSTextField(labelWithString:
            state.mic ? "One more permission needed"
                      : "Ghostie can't record calls yet")
        title.font = .systemFont(ofSize: 13.5, weight: .semibold)
        title.textColor = Theme.text
        let sub = NSTextField(wrappingLabelWithString:
            "macOS needs your okay before Ghostie can listen to a call.")
        sub.font = .systemFont(ofSize: 12)
        sub.textColor = Theme.text2
        let textStack = NSStackView(views: [title, sub])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 2
        textStack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(badge); header.addSubview(textStack)
        NSLayoutConstraint.activate([
            badge.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 14),
            badge.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            badge.widthAnchor.constraint(equalToConstant: 26),
            badge.heightAnchor.constraint(equalToConstant: 26),
            bang.centerXAnchor.constraint(equalTo: badge.centerXAnchor),
            bang.centerYAnchor.constraint(equalTo: badge.centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12),
            textStack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -14),
            textStack.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            header.bottomAnchor.constraint(equalTo: textStack.bottomAnchor, constant: 10)
        ])
        addSubview(header)

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 0
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.wantsLayer = true
        inner.layer?.backgroundColor = themedCG(Theme.cardBg)
        addSubview(inner)

        themeRefresh = { [weak self, weak badge, weak inner] in
            self?.layer?.borderColor = Theme.warn.cgColor
            self?.layer?.backgroundColor = Theme.warnSoft.cgColor
            badge?.layer?.backgroundColor = Theme.warn.cgColor
            inner?.layer?.backgroundColor = Theme.cardBg.cgColor
        }

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),
            header.topAnchor.constraint(equalTo: topAnchor),
            inner.topAnchor.constraint(equalTo: header.bottomAnchor),
            inner.leadingAnchor.constraint(equalTo: leadingAnchor),
            inner.trailingAnchor.constraint(equalTo: trailingAnchor),
            inner.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        var first = true
        if !state.mic {
            inner.addArrangedSubview(permRow(
                first: first, name: "Microphone",
                why: state.micDenied
                    ? "Currently blocked. Turn this on in System Settings so Ghostie can capture your voice."
                    : "Lets Ghostie capture your voice during a call.",
                symbol: "mic",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"))
            first = false
        }
        if !state.screen {
            inner.addArrangedSubview(permRow(
                first: first, name: "Screen Recording",
                why: "Lets Ghostie capture the other participants. Only the audio is kept, never the picture.",
                symbol: "display",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"))
            first = false
        }
        if !state.ax {
            inner.addArrangedSubview(permRow(
                first: first, name: "Accessibility", optional: true,
                why: "Helps Ghostie tell a real Teams meeting apart from the app just being open.",
                symbol: "figure.stand",
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"))
            first = false
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func permRow(first: Bool, name: String, optional: Bool = false,
                         why: String, symbol: String, url: String) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let divider = DividerView()
        divider.translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .regular))
        icon.contentTintColor = Theme.text2

        let title = NSMutableAttributedString(
            string: name, attributes: [
                .foregroundColor: Theme.text,
                .font: NSFont.systemFont(ofSize: 12.5, weight: .medium)
            ])
        if optional {
            title.append(NSAttributedString(
                string: "  ·  optional", attributes: [
                    .foregroundColor: Theme.text3,
                    .font: NSFont.systemFont(ofSize: 11)
                ]))
        }
        let titleL = NSTextField(labelWithAttributedString: title)
        titleL.translatesAutoresizingMaskIntoConstraints = false
        let whyL = NSTextField(wrappingLabelWithString: why)
        whyL.font = .systemFont(ofSize: 11)
        whyL.textColor = Theme.text2
        whyL.translatesAutoresizingMaskIntoConstraints = false
        whyL.preferredMaxLayoutWidth = 380
        let textStack = NSStackView(views: [titleL, whyL])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 1
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let target = OpenURLTarget(url: url)
        let btn = StyledButton(title: "Open in System Settings",
                               target: target, action: #selector(OpenURLTarget.fire))
        btn.kind = .primary
        objc_setAssociatedObject(btn, &OpenURLTarget.key, target, .OBJC_ASSOCIATION_RETAIN)

        row.addSubview(icon)
        row.addSubview(textStack)
        row.addSubview(btn)
        if !first { row.addSubview(divider) }
        var consts: [NSLayoutConstraint] = [
            icon.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 15),
            icon.heightAnchor.constraint(equalToConstant: 15),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            textStack.topAnchor.constraint(equalTo: row.topAnchor, constant: 9),
            textStack.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -9),
            btn.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -14),
            btn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            btn.leadingAnchor.constraint(greaterThanOrEqualTo: textStack.trailingAnchor, constant: 12)
        ]
        if !first {
            consts += [
                divider.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 14),
                divider.trailingAnchor.constraint(equalTo: row.trailingAnchor),
                divider.topAnchor.constraint(equalTo: row.topAnchor),
                divider.heightAnchor.constraint(equalToConstant: 0.5)
            ]
        }
        NSLayoutConstraint.activate(consts)
        return row
    }
}

private final class OpenURLTarget {
    static var key: UInt8 = 0
    let url: String
    init(url: String) { self.url = url }
    @objc func fire() {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
