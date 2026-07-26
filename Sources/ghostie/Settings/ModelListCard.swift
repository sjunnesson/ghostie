import AppKit

/// The **storage** view of models: what's downloaded, how big, is it intact,
/// delete it. Nothing here knows about languages.
///
/// v3 moved this out of the Transcription pane and into Developer. It used to
/// carry double duty — a `+ −` list that was simultaneously "manage disk" and
/// "the way you add a language" — which is why its row tickmark had to mean
/// three different things depending on how many languages were active. The
/// language list owns language intent now; this owns bytes on disk.
final class ModelListCard: NSView {

    private struct RowState {
        let row: ModelRowView
        let entry: CatalogEntry
    }

    private var kbVariant: String
    private let rowAction: (String) -> Void
    private let addModel: () -> Void
    private let removeModel: (String) -> Void

    private let card = GroupCard(title: "Downloaded models")
    private var rows: [String: RowState] = [:]
    /// The row selected for the `−` button.
    private var selectedKey: String?
    /// Presets whose download is in flight — shown in the list while
    /// downloading even though they're not on disk yet.
    private var pendingKeys: Set<String> = []
    /// Full-hash verdicts from the explicit Verify / Re-verify row actions,
    /// keyed by row. Routine refreshes skip the SHA256 (existence + sidecar
    /// size only — hashing ~1.1 GB on the main thread froze the pane), so a
    /// hash mismatch can only be discovered by those actions; remember it here
    /// so the badge and the action button keep reporting it until a
    /// re-download settles.
    private var verifiedStates: [String: ModelDownloader.HealthState] = [:]
    private weak var footerSeg: NSSegmentedControl?
    /// Retains the `+` menu's action target while the menu is open.
    private var menuTarget: MenuTarget?

    init(kbVariant: String,
         rowAction: @escaping (String) -> Void,
         addModel: @escaping () -> Void,
         removeModel: @escaping (String) -> Void) {
        self.kbVariant = kbVariant
        self.rowAction = rowAction
        self.addModel = addModel
        self.removeModel = removeModel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: topAnchor),
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    func applyKBVariant(_ variant: String) {
        kbVariant = variant
        rebuild()
    }

    /// One row per *installed* model (on disk, a built-in preset whose download
    /// is in flight, or any custom entry), an empty-state line when there are
    /// none, and a `+ −` footer — the macOS list-with-toolbar pattern.
    func rebuild() {
        card.clearRows()
        rows.removeAll()

        let fm = FileManager.default
        let listed = ModelCatalog.load().filter { e in
            guard let m = e.model() else { return false }
            return !e.builtin || fm.fileExists(atPath: m.destPath) || pendingKeys.contains(e.filename)
        }
        if listed.isEmpty {
            card.addRow(RowBuilder.row(
                label: "Nothing downloaded yet",
                sub: "Add a language in Transcription and Ghostie fetches the model it needs."))
        } else {
            for e in listed {
                let key = e.filename
                let row = ModelRowView(title: e.label, subtitle: subtitle(for: e))
                row.onAction = { [weak self] in self?.rowAction(key) }
                row.onSelect = { [weak self] in self?.select(key) }
                card.addRow(row)
                rows[key] = RowState(row: row, entry: e)
            }
        }
        card.addRow(buildFooter(), last: true)

        if let sel = selectedKey, rows[sel] == nil { selectedKey = nil }
        refreshAllRows()
        if let sel = selectedKey { rows[sel]?.row.setHighlighted(true) }
    }

    /// A download settled (finished / failed / cancelled): drop it from the
    /// pending set and rebuild so a failed preset disappears and a finished one
    /// stays, shown by its on-disk status.
    func downloadDidSettle(_ key: String) {
        pendingKeys.remove(key)
        verifiedStates[key] = nil   // file replaced or removed — verdict is stale
        rebuild()
    }

    /// Show a row for a model whose download is starting before it exists.
    func markPending(_ key: String) {
        pendingKeys.insert(key)
        rebuild()
    }

    /// Last full-hash verdict for a row, if an explicit Verify / Re-verify has
    /// run. The hash-free refresh path can't tell ok from hashMismatch.
    func verifiedState(_ key: String) -> ModelDownloader.HealthState? { verifiedStates[key] }

    /// Land the result of an off-main Verify / Re-verify: remember the verdict
    /// and redraw the row with it.
    func recordVerifiedState(_ state: ModelDownloader.HealthState, forKey key: String) {
        verifiedStates[key] = state
        refreshRow(key)
    }

    func setRowDownloading(_ key: String, percent: Double, status: String) {
        rows[key]?.row.setDownloading(percent: percent, status: status)
    }
    func setRowBusy(_ key: String, status: String) {
        rows[key]?.row.setBusy(status: status)
    }

    func refreshAllRows() { for key in rows.keys { refreshRow(key) } }

    func refreshRow(_ key: String) {
        guard let st = rows[key], let model = st.entry.model() else { return }
        // Hash-free: this runs on pane build and every refresh, and a SHA256 of
        // a ~1.1 GB model is ~3 s on the main thread. A mismatch verdict from an
        // explicit Verify / Re-verify overlays the cheap check.
        var state = ModelDownloader.health(for: [model], verifyHash: false)[0].state
        if case .ok = state, let verdict = verifiedStates[key] { state = verdict }
        st.row.apply(state: state)
    }

    // MARK: Internals

    /// One-line description per catalog entry: which language it decodes (and
    /// whether it also drives detection), the VAD note for the VAD model, or an
    /// honest "this does nothing" for a language-less entry.
    ///
    /// That last case is reachable: the pre-v3 "Add a model" form took the
    /// language as free text and happily accepted an empty one, leaving an
    /// entry the pipeline can never route to (`Models.decodeModels` drops
    /// empty-language entries). Labelling those as voice-activity — which is
    /// what this did — hid the problem behind a plausible sentence.
    private func subtitle(for e: CatalogEntry) -> String {
        if e.filename == Models.sileroVAD.filename {
            return "Voice activity — lets Ghostie skip silent stretches so it doesn't invent words."
        }
        if e.language.isEmpty {
            return "No language set, so Ghostie never uses this. Select it and press − to clear it out."
        }
        let base = "Decodes \(WhisperLanguages.displayName(e.language))."
        return e.goodForLID ? base + " Can also tell languages apart." : base
    }

    /// The `+ −` toolbar beneath the list.
    private func buildFooter() -> NSView {
        let seg = NSSegmentedControl()
        seg.segmentStyle = .smallSquare
        seg.trackingMode = .momentary
        seg.segmentCount = 2
        seg.setImage(NSImage(systemSymbolName: "plus", accessibilityDescription: "Add"), forSegment: 0)
        seg.setImage(NSImage(systemSymbolName: "minus", accessibilityDescription: "Remove"), forSegment: 1)
        seg.setWidth(34, forSegment: 0)
        seg.setWidth(34, forSegment: 1)
        seg.setEnabled(selectedKey != nil, forSegment: 1)
        seg.translatesAutoresizingMaskIntoConstraints = false
        let target = ActionTarget { [weak self, weak seg] in
            guard let self, let seg else { return }
            if seg.selectedSegment == 0 { self.showAddMenu(from: seg) }
            else if let sel = self.selectedKey { self.removeModel(sel) }
        }
        seg.target = target
        seg.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(seg, &ActionTarget.key, target, .OBJC_ASSOCIATION_RETAIN)
        footerSeg = seg

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(seg)
        NSLayoutConstraint.activate([
            seg.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            seg.topAnchor.constraint(equalTo: container.topAnchor, constant: 6),
            seg.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6),
            seg.heightAnchor.constraint(equalToConstant: 22)
        ])
        return container
    }

    private func select(_ key: String) {
        selectedKey = key
        for (k, st) in rows { st.row.setHighlighted(k == key) }
        footerSeg?.setEnabled(true, forSegment: 1)
    }

    /// `+` menu: predefined models not yet installed, then "Add from Hugging Face…".
    private func showAddMenu(from view: NSView) {
        let fm = FileManager.default
        let presets = ModelCatalog.load().filter { e in
            guard e.builtin, let m = e.model() else { return false }
            return !fm.fileExists(atPath: m.destPath) && !pendingKeys.contains(e.filename)
        }
        let menu = NSMenu()
        let target = MenuTarget { [weak self] item in
            guard let self else { return }
            if let fn = item.representedObject as? String {
                self.markPending(fn)
                self.rowAction(fn)      // → handleModelRowAction → startDownload (.missing)
            } else {
                self.addModel()
            }
        }
        menuTarget = target
        for e in presets {
            let it = NSMenuItem(title: e.label, action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
            it.representedObject = e.filename
            it.target = target
            menu.addItem(it)
        }
        if !presets.isEmpty { menu.addItem(.separator()) }
        let custom = NSMenuItem(title: "Add from Hugging Face…",
                                action: #selector(MenuTarget.fire(_:)), keyEquivalent: "")
        custom.target = target
        menu.addItem(custom)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
    }
}

/// Block-based target for `NSMenuItem`s — the item is passed back so the
/// handler can read its `representedObject`.
final class MenuTarget: NSObject {
    private let handler: (NSMenuItem) -> Void
    init(_ handler: @escaping (NSMenuItem) -> Void) { self.handler = handler }
    @objc func fire(_ sender: NSMenuItem) { handler(sender) }
}

// MARK: - Model row

/// One file on disk: name, what it decodes, health badge, and the one action
/// that health implies. v3 dropped the leading tickmark — it used to mean
/// "VAD present" *or* "this is the single-language pick" *or* "this language is
/// in the whitelist" depending on state, which is three facts wearing one glyph.
/// Which model serves which language is now stated in words, in the language list.
final class ModelRowView: NSView {
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")
    private let badge = StatusBadgeView(kind: .muted, label: "Not downloaded")
    private let action: StyledButton
    private let progressBar = ProgressBar()
    private let statusLine = NSTextField(labelWithString: "")
    private var progressHeight: NSLayoutConstraint!
    private var statusHeight: NSLayoutConstraint!
    private var subtitleToBottom: NSLayoutConstraint!
    private var statusToBottom: NSLayoutConstraint!
    var onAction: (() -> Void)?
    /// Click anywhere on the row (not the action button) to select it for the
    /// `−` button — the macOS list pattern.
    var onSelect: (() -> Void)?

    init(title: String, subtitle: String) {
        self.action = StyledButton(title: "Download", target: nil, action: nil)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 5
        // Click anywhere on the row (a gesture recognizer fires even over the
        // non-interactive labels, which would otherwise swallow `mouseDown`).
        // Don't delay primary mouse events, so the action button still works.
        let click = NSClickGestureRecognizer(target: self, action: #selector(rowClicked))
        click.delaysPrimaryMouseButtonEvents = false
        addGestureRecognizer(click)

        self.title.stringValue = title
        self.title.font = .systemFont(ofSize: 13, weight: .semibold)
        self.title.textColor = Theme.text
        self.title.translatesAutoresizingMaskIntoConstraints = false
        self.title.setContentHuggingPriority(.required, for: .horizontal)

        self.subtitle.stringValue = subtitle
        self.subtitle.font = .systemFont(ofSize: 11.5)
        self.subtitle.textColor = Theme.text2
        self.subtitle.translatesAutoresizingMaskIntoConstraints = false

        statusLine.font = .systemFont(ofSize: 11)
        statusLine.textColor = Theme.text2
        statusLine.translatesAutoresizingMaskIntoConstraints = false
        statusLine.isHidden = true

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        progressBar.isHidden = true

        // Pin the action button to a fixed width so the badge column to its
        // left lands at a consistent X across all rows. Long enough to fit the
        // widest label ("Re-download") without truncating.
        action.widthAnchor.constraint(equalToConstant: 110).isActive = true
        badge.translatesAutoresizingMaskIntoConstraints = false

        let actionTarget = ActionTarget { [weak self] in self?.onAction?() }
        action.target = actionTarget
        action.action = #selector(ActionTarget.fire)
        objc_setAssociatedObject(action, &ActionTarget.key, actionTarget, .OBJC_ASSOCIATION_RETAIN)

        addSubview(self.title)
        addSubview(self.subtitle)
        addSubview(badge)
        addSubview(action)
        addSubview(progressBar)
        addSubview(statusLine)

        // Progress and status carry their own height constraints, toggled to 0
        // when hidden so the row collapses to title + subtitle without leaving
        // phantom space.
        progressHeight = progressBar.heightAnchor.constraint(equalToConstant: 0)
        statusHeight = statusLine.heightAnchor.constraint(equalToConstant: 0)
        progressHeight.isActive = true
        statusHeight.isActive = true

        subtitleToBottom = bottomAnchor.constraint(equalTo: self.subtitle.bottomAnchor, constant: 11)
        statusToBottom = bottomAnchor.constraint(equalTo: statusLine.bottomAnchor, constant: 9)
        subtitleToBottom.isActive = true

        NSLayoutConstraint.activate([
            self.title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            self.title.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            self.title.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),

            self.subtitle.leadingAnchor.constraint(equalTo: self.title.leadingAnchor),
            self.subtitle.topAnchor.constraint(equalTo: self.title.bottomAnchor, constant: 2),
            self.subtitle.trailingAnchor.constraint(lessThanOrEqualTo: badge.leadingAnchor, constant: -10),

            // Right-aligned badge column, pinned a fixed distance from the
            // action button's leading edge so every pill lines up.
            badge.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -12),
            badge.centerYAnchor.constraint(equalTo: self.title.centerYAnchor),

            progressBar.leadingAnchor.constraint(equalTo: self.title.leadingAnchor),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            progressBar.topAnchor.constraint(equalTo: self.subtitle.bottomAnchor, constant: 8),

            statusLine.leadingAnchor.constraint(equalTo: self.title.leadingAnchor),
            statusLine.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 3),
            statusLine.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),

            action.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            action.centerYAnchor.constraint(equalTo: self.title.centerYAnchor)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func rowClicked() { onSelect?() }

    func setHighlighted(_ on: Bool) {
        layer?.backgroundColor = on ? Theme.accent.withAlphaComponent(0.14).cgColor
                                    : NSColor.clear.cgColor
    }

    private func setProgressVisible(_ visible: Bool) {
        progressBar.isHidden = !visible
        statusLine.isHidden = !visible
        progressHeight.constant = visible ? 4 : 0
        statusHeight.constant = visible ? 14 : 0
        subtitleToBottom.isActive = !visible
        statusToBottom.isActive = visible
    }

    func apply(state: ModelDownloader.HealthState) {
        setProgressVisible(false)
        switch state {
        case .ok:
            badge.set(kind: .ok, label: "On disk")
            action.title = "Re-verify"
            action.kind = .secondary
        case .missing:
            badge.set(kind: .muted, label: "Not downloaded")
            action.title = "Download"
            action.kind = .primary
        case .noSidecar:
            badge.set(kind: .warn, label: "Unverified")
            action.title = "Verify"
            action.kind = .secondary
        case .sizeWrong, .hashMismatch:
            badge.set(kind: .danger, label: "Mismatch")
            action.title = "Re-download"
            action.kind = .primary
        }
    }
    func setDownloading(percent: Double, status: String) {
        badge.set(kind: .info, label: "Downloading")
        action.title = "Cancel"
        action.kind = .secondary
        setProgressVisible(true)
        progressBar.set(progress: percent)
        statusLine.stringValue = status
    }
    func setBusy(status: String) {
        // Verify / re-hash: status line only, no progress bar — but we still
        // need somewhere to land the message. Reuse the progress slot with a
        // zero bar.
        setProgressVisible(true)
        progressBar.set(progress: 0)
        statusLine.stringValue = status
        action.title = "Working…"
        action.kind = .secondary
    }
}

/// Thin determinate bar used by both the model rows and the language rows.
final class ProgressBar: NSView {
    private var progress: CGFloat = 0
    private let fillLayer = CALayer()
    override var isFlipped: Bool { true }
    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 2
        layer?.backgroundColor = themedCG(Theme.chipBg)
        layer?.masksToBounds = true
        fillLayer.backgroundColor = themedCG(Theme.accent)
        fillLayer.cornerRadius = 2
        layer?.addSublayer(fillLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        // Drive the fill from layout (not updateLayer); previously this ran
        // inside updateLayer + re-added a sublayer on every pass, which
        // accumulated layers and reentered display.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.frame = CGRect(x: 0, y: 0,
                                  width: bounds.width * progress,
                                  height: bounds.height)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = themedCG(Theme.chipBg)
        fillLayer.backgroundColor = themedCG(Theme.accent)
    }
    func set(progress: Double) {
        let p = CGFloat(max(0, min(1, progress)))
        guard p != self.progress else { return }
        self.progress = p
        needsLayout = true
    }
}
