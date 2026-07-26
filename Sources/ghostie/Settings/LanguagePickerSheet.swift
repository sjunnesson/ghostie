import AppKit

/// The one dialog for "which language, served by which model".
///
/// It replaces a free-text ISO-code field (`placeholder: "ar"`, no validation —
/// typing `swe` or `German` produced a language the LID can never emit, and
/// nothing ever said so) with a picker over exactly the labels Whisper can
/// return. The model choice sits in the same sheet because the two decisions
/// are one decision: a language Ghostie can't decode isn't a language it
/// supports.
enum LanguagePickerSheet {

    enum ModelChoice: Equatable {
        /// No pin — use the best installed model for this language, and fetch
        /// the catalog's recommendation if there isn't one yet.
        case auto
        /// A specific catalog entry, by filename.
        case catalog(String)
        /// A Hugging Face repo / file URL to resolve and register.
        case huggingFace(String)
    }

    struct Choice {
        let code: String
        let model: ModelChoice
        /// Whether this model is a balanced multilingual one — able to decode
        /// other languages *and* to identify which is being spoken. Only asked
        /// for custom models: pre-v3 every custom entry was silently written
        /// `goodForLID: false` (the comment claimed a checkbox wrote it; there
        /// was no checkbox), so adding a third language could quietly break
        /// routing for the two that already worked.
        ///
        /// One checkbox sets both `goodForLID` and `multilingual`: the two come
        /// apart only for a specialist with a biased language head, which is a
        /// built-in's problem (KB-Whisper), not something worth making a user
        /// reason about when pasting a repo.
        let isMultilingual: Bool
    }

    /// Run the sheet modally. Returns nil when cancelled or when the input
    /// doesn't make sense (an explained alert has already been shown).
    ///
    /// - excluding: languages already in the list, greyed out of the picker.
    /// - fixedLanguage: lock the language (the "change model" case).
    /// - startOnHuggingFace: preselect the custom-model row.
    static func run(excluding taken: Set<String>,
                    fixedLanguage: String? = nil,
                    kbVariant: String,
                    title: String,
                    confirm: String,
                    startOnHuggingFace: Bool = false) -> Choice? {

        let catalog = ModelCatalog.load()
        let fm = FileManager.default

        // ---- Language picker ---------------------------------------------
        let langPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        langPopup.translatesAutoresizingMaskIntoConstraints = false
        langPopup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        // Items carry no target/action, so AppKit's automatic enabling would
        // override `isEnabled` and the already-added languages would look
        // pickable. Own the enabled state explicitly.
        langPopup.menu?.autoenablesItems = false
        var codesInMenu: [String?] = []          // parallel to menu items; nil = separator/placeholder

        func addLanguageItem(_ code: String) {
            let item = NSMenuItem(title: WhisperLanguages.label(code), action: nil, keyEquivalent: "")
            if taken.contains(code) {
                item.isEnabled = false
                item.title += "  (already added)"
            }
            langPopup.menu?.addItem(item)
            codesInMenu.append(code)
        }
        func addSeparator() {
            langPopup.menu?.addItem(.separator())
            codesInMenu.append(nil)
        }

        if let fixed = fixedLanguage {
            addLanguageItem(fixed)
            langPopup.isEnabled = false
        } else {
            // Nothing is preselected: the alphabetically-first selectable
            // language would otherwise sit there looking chosen, one stray
            // Return away from adding Afrikaans.
            let placeholder = NSMenuItem(title: "Choose a language…", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            langPopup.menu?.addItem(placeholder)
            codesInMenu.append(nil)
            addSeparator()

            // Suggestions next: the system language, anything already
            // downloaded, then the common ones. Everything else follows
            // alphabetically — the list is 99 long, and scrolling to Swedish
            // past Sinhala and Slovak is not a good first experience.
            var suggested: [String] = []
            func suggest(_ code: String) {
                guard WhisperLanguages.isSupported(code), !taken.contains(code),
                      !suggested.contains(code) else { return }
                suggested.append(code)
            }
            if let sys = Locale.current.language.languageCode?.identifier { suggest(sys) }
            for e in catalog where !e.language.isEmpty {
                guard let m = e.model(), fm.fileExists(atPath: m.destPath) else { continue }
                suggest(e.language)
            }
            for code in WhisperLanguages.common { suggest(code) }
            for code in suggested { addLanguageItem(code) }
            if !suggested.isEmpty { addSeparator() }
            for l in WhisperLanguages.allSortedByName() where !suggested.contains(l.code) {
                addLanguageItem(l.code)
            }
            langPopup.selectItem(at: 0)
        }

        // ---- Model picker -------------------------------------------------
        let modelPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        modelPopup.translatesAutoresizingMaskIntoConstraints = false
        modelPopup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        var modelChoices: [ModelChoice] = []

        let repoField = NSTextField(string: "")
        repoField.placeholderString = "KBLab/kb-whisper-large"
        repoField.translatesAutoresizingMaskIntoConstraints = false
        repoField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        let lidBox = NSButton(checkboxWithTitle: "This model handles many languages, not just this one",
                              target: nil, action: nil)
        lidBox.toolTip = "Tick only for a balanced multilingual model (like large-v3): Ghostie will let it decode other languages too, and let it decide which language is being spoken. A single-language specialist will mis-route everything if it drives detection."

        let note = NSTextField(wrappingLabelWithString: "")
        note.font = .systemFont(ofSize: 11)
        note.textColor = Theme.text2
        note.translatesAutoresizingMaskIntoConstraints = false
        note.widthAnchor.constraint(equalToConstant: 380).isActive = true

        /// Repopulate the model list for the selected language. The
        /// recommendation is `ModelCatalog.recommended`, which ranks entries
        /// the same way `Models.installed` picks between siblings — so the
        /// model offered here is the model the pipeline would choose.
        func selectedCode() -> String {
            let i = langPopup.indexOfSelectedItem
            guard i >= 0, i < codesInMenu.count, let c = codesInMenu[i] else { return "" }
            return c
        }

        func refreshModels() {
            let code = selectedCode()
            modelPopup.removeAllItems()
            modelChoices.removeAll()

            // No language chosen yet — nothing sensible to offer.
            guard !code.isEmpty else {
                modelPopup.addItem(withTitle: "—")
                modelPopup.isEnabled = false
                repoField.isEnabled = false
                lidBox.isEnabled = false
                note.stringValue = "Pick a language first."
                return
            }
            modelPopup.isEnabled = true

            let entries = ModelCatalog.entries(for: code, in: catalog, kbVariant: kbVariant)
            if let best = entries.first {
                let onDisk = (best.model().map { fm.fileExists(atPath: $0.destPath) }) ?? false
                modelPopup.addItem(withTitle: onDisk
                    ? "Recommended — \(best.label) (already here)"
                    : "Recommended — \(best.label)")
                modelChoices.append(.auto)
            }
            for e in entries.dropFirst() {
                let onDisk = (e.model().map { fm.fileExists(atPath: $0.destPath) }) ?? false
                modelPopup.addItem(withTitle: onDisk ? "\(e.label) (already here)" : e.label)
                modelChoices.append(.catalog(e.filename))
            }
            modelPopup.addItem(withTitle: "From Hugging Face…")
            modelChoices.append(.huggingFace(""))

            if startOnHuggingFace || entries.isEmpty {
                modelPopup.selectItem(at: modelPopup.numberOfItems - 1)
            } else {
                modelPopup.selectItem(at: 0)
            }
            refreshCustomState()
        }

        func refreshCustomState() {
            let i = modelPopup.indexOfSelectedItem
            let isCustom = i >= 0 && i < modelChoices.count && modelChoices[i] == .huggingFace("")
            repoField.isEnabled = isCustom
            lidBox.isEnabled = isCustom
            let code = selectedCode()
            if isCustom {
                note.stringValue = ModelCatalog.entries(for: code, in: catalog, kbVariant: kbVariant).isEmpty
                    ? "Ghostie doesn't ship a model for \(WhisperLanguages.displayName(code)). Paste a Hugging Face repo and it'll find the GGML file."
                    : "Paste a Hugging Face repo (org/name) and Ghostie will find the GGML file in it."
            } else {
                // The model's own label already carries its size, so don't
                // quote a second (differently-rounded) figure next to it —
                // say what will actually happen instead.
                note.stringValue = selectedIsOnDisk()
                    ? "Already downloaded — Ghostie will use it as it is."
                    : "Ghostie downloads this once and then runs it locally."
            }
        }

        func selectedIsOnDisk() -> Bool {
            let code = selectedCode()
            let entries = ModelCatalog.entries(for: code, in: catalog, kbVariant: kbVariant)
            let i = modelPopup.indexOfSelectedItem
            guard i >= 0, i < modelChoices.count else { return false }
            let entry: CatalogEntry?
            switch modelChoices[i] {
            case .auto:           entry = entries.first
            case .catalog(let f): entry = entries.first { $0.filename == f }
            case .huggingFace:    entry = nil
            }
            return entry?.model().map { fm.fileExists(atPath: $0.destPath) } ?? false
        }

        let langTarget = ToggleTarget { refreshModels() }
        langPopup.target = langTarget
        langPopup.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(langPopup, &ToggleTarget.key, langTarget, .OBJC_ASSOCIATION_RETAIN)

        let modelTarget = ToggleTarget { refreshCustomState() }
        modelPopup.target = modelTarget
        modelPopup.action = #selector(ToggleTarget.fire)
        objc_setAssociatedObject(modelPopup, &ToggleTarget.key, modelTarget, .OBJC_ASSOCIATION_RETAIN)

        refreshModels()

        // ---- Layout --------------------------------------------------------
        func lbl(_ s: String) -> NSTextField {
            let t = NSTextField(labelWithString: s)
            t.alignment = .right
            return t
        }
        let grid = NSGridView(views: [
            [lbl("Language"), langPopup],
            [lbl("Model"),    modelPopup],
            [lbl("Repo"),     repoField],
            [NSGridCell.emptyContentView, lidBox],
            [NSGridCell.emptyContentView, note]
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 10
        grid.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 190))
        container.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: container.topAnchor),
            grid.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: container.trailingAnchor)
        ])

        let a = NSAlert()
        a.messageText = title
        a.informativeText = fixedLanguage == nil
            ? "Ghostie detects which of your languages each speaker is using and sends it to that language's model. Everything runs locally."
            : "Which model should decode this language."
        a.accessoryView = container
        a.addButton(withTitle: confirm)
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { return nil }

        let code = selectedCode()
        guard !code.isEmpty else {
            let e = NSAlert()
            e.alertStyle = .warning
            e.messageText = "Which language?"
            e.informativeText = "Pick the language you want Ghostie to understand, then choose a model for it."
            e.runModal()
            return nil
        }
        let i = modelPopup.indexOfSelectedItem
        guard i >= 0, i < modelChoices.count else { return nil }

        switch modelChoices[i] {
        case .huggingFace:
            let raw = repoField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else {
                let e = NSAlert()
                e.alertStyle = .warning
                e.messageText = "Which model?"
                e.informativeText = "Enter a Hugging Face repo, like KBLab/kb-whisper-large."
                e.runModal()
                return nil
            }
            return Choice(code: code, model: .huggingFace(raw), isMultilingual: lidBox.state == .on)
        case .auto:
            return Choice(code: code, model: .auto, isMultilingual: false)
        case .catalog(let filename):
            return Choice(code: code, model: .catalog(filename), isMultilingual: false)
        }
    }
}
