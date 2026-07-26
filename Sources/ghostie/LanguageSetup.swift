import Foundation

/// The complete answer to "what will Ghostie do with languages on this
/// machine, right now" — computed once, in one place, from config + catalog +
/// disk.
///
/// This exists because the same question used to be answered independently by
/// the Settings pane (checkbox states, model rows, per-language prompt fields),
/// by `doctor`, and by the pipeline — three renderings of the same facts that
/// had to be kept in step by hand and drifted. Everything here is **pure**:
/// `present` is the on-disk test, so the whole thing is unit-testable without a
/// filesystem, and the pane becomes render-only.
struct LanguageSetup {

    /// What the model backing a language is doing.
    enum ModelState: Equatable {
        /// A model is chosen and present in `~/.ghostie/models/`.
        case onDisk
        /// A model is chosen but not downloaded yet.
        case missing
        /// No model is known for this language at all — the catalog has no
        /// entry and the user hasn't pointed at one.
        case none
    }

    /// How the pipeline will run. Stated in the UI because the two modes obey
    /// different settings and the boundary used to be invisible: adding a
    /// second language silently changed what "Model for one-language calls"
    /// meant.
    enum Mode: Equatable {
        /// No usable model at all — nothing can be transcribed yet.
        case unconfigured
        /// One language: the single-whisper-pass path, `transcriptionQuality`
        /// picks the model.
        case single(String)
        /// Two or more: detect per speaker and route to each language's model.
        case codeSwitch([String])
    }

    /// Something the user should know about, in the order it should be shown.
    enum Warning: Equatable {
        /// ≥2 languages but no balanced multilingual model on disk, so
        /// `resolveDetectionModel` has nothing good to route with. The single
        /// most consequential thing the old UI never mentioned.
        case noDetectionModel
        /// ≥2 languages and the Silero VAD model is absent. Code-switching
        /// cannot segment without it.
        case vadMissing
        /// This language's model isn't downloaded yet.
        case modelMissing(code: String)
        /// This language has no model to download — the catalog knows nothing
        /// that decodes it.
        case noModelForLanguage(code: String)
    }

    /// One configured language, with everything the UI needs to draw a row.
    struct Row: Equatable {
        let code: String
        /// Localized display name ("German").
        let name: String
        /// Catalog filename of the model serving this language — the key used
        /// for downloads, verification and the `.meta` sidecar. nil when the
        /// language resolves to an out-of-catalog absolute path, or to nothing.
        let modelFilename: String?
        /// Human label of that model ("Whisper large-v3 (Q5) · ~1.1 GB").
        let modelLabel: String?
        /// Absolute GGML path, whether or not it's downloaded yet.
        let modelPath: String?
        let approxBytes: Int64
        let state: ModelState
        /// The tiebreak language (`dominantLanguage`), clamped to what's usable.
        let isPrimary: Bool
        /// This language's model is the one that will drive language detection.
        let drivesDetection: Bool
        /// The user pinned this model explicitly rather than taking the
        /// auto-pick, so Settings can offer to un-pin it.
        let modelIsExplicit: Bool
    }

    let rows: [Row]
    let mode: Mode
    /// Label of the model that will drive the `--detect-language` head, or nil
    /// when nothing suitable is installed.
    let detectionModelLabel: String?
    let warnings: [Warning]
    /// True when the user has an explicit `languages` list; false while the
    /// install is still disk-driven. Settings materializes records on the
    /// first edit, so this flips exactly once.
    let isConfigured: Bool

    /// Languages that will actually reach the pipeline, in priority order.
    var activeCodes: [String] { rows.filter { $0.state == .onDisk }.map(\.code) }

    // MARK: Resolution

    /// Compute the setup. `present` is the on-disk existence test — inject it
    /// to resolve against a hypothetical disk in tests.
    static func resolve(config: Config,
                        catalog: [CatalogEntry] = ModelCatalog.load(),
                        present: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> LanguageSetup {

        let cs = config.codeSwitch
        let installed = Models.installed(from: catalog,
                                         preferredKBVariant: cs.kbWhisperVariant,
                                         present: present)
        // The displayed set: configured languages when there are any, else
        // whatever the disk can decode. Either way it's what the pipeline sees,
        // so the pane can never show a language the pipeline doesn't know about.
        let codes: [String] = cs.languages.isEmpty
            ? installed.languages
            : dedupe(cs.languages.map(\.code))

        let dominant = cs.effectiveDominant(installed: installed, present: present)
        let driverPath = LanguageSegmenter.resolveDetectionModel(
            config: config, installed: installed, present: present)
        let decodeModels = Models.decodeModels(from: catalog)
        let driverIsUsable = !driverPath.isEmpty
            && present(driverPath)
            && !Models.isBadLIDDriver(path: driverPath, in: decodeModels)
        let driverEntry = catalog.first { $0.model()?.destPath == driverPath }

        var rows: [Row] = []
        var warnings: [Warning] = []

        for code in codes {
            // Priority: the record's explicit model, then the best model
            // already installed for this language, then the best the catalog
            // could download for it.
            let explicit = CodeSwitchConfig.resolveModelReference(
                cs.setting(for: code)?.model ?? "", kbVariant: cs.kbWhisperVariant)
            // `decodePath`, not `modelPath`: a language with no specialist is
            // still served by an installed multilingual model, which is what
            // makes German and Spanish work with no extra download.
            let installedPath = installed.decodePath(for: code)
            let recommended = ModelCatalog.recommended(for: code, in: catalog,
                                                       kbVariant: cs.kbWhisperVariant)

            let path: String?
            let modelIsExplicit: Bool
            if !explicit.isEmpty {
                path = explicit
                modelIsExplicit = true
            } else if let installedPath {
                path = installedPath
                modelIsExplicit = false
            } else {
                path = recommended?.model()?.destPath
                modelIsExplicit = false
            }

            let entry = path.flatMap { p in catalog.first { $0.model()?.destPath == p } }
            let state: ModelState
            if let path {
                state = present(path) ? .onDisk : .missing
            } else {
                state = .none
            }
            switch state {
            case .missing: warnings.append(.modelMissing(code: code))
            case .none:    warnings.append(.noModelForLanguage(code: code))
            case .onDisk:  break
            }

            rows.append(Row(
                code: code,
                name: WhisperLanguages.displayName(code),
                modelFilename: entry?.filename,
                modelLabel: entry?.label ?? path.map { ($0 as NSString).lastPathComponent },
                modelPath: path,
                approxBytes: entry?.approxBytes ?? 0,
                state: state,
                isPrimary: code == dominant,
                // Only a model that's actually on disk can be driving detection.
                drivesDetection: driverIsUsable && path == driverPath && state == .onDisk,
                modelIsExplicit: modelIsExplicit))
        }

        let active = rows.filter { $0.state == .onDisk }.map(\.code)
        let mode: Mode
        switch active.count {
        case 0:  mode = .unconfigured
        case 1:  mode = .single(active[0])
        default: mode = .codeSwitch(active)
        }

        // Code-switching prerequisites. Both are silent failures at runtime —
        // detection falls back to a biased model, segmentation throws — so
        // they're stated up front rather than left to `doctor`.
        if active.count >= 2 {
            if !driverIsUsable { warnings.insert(.noDetectionModel, at: 0) }
            let vadPath = config.vadModel.isEmpty ? Models.sileroVAD.destPath : config.vadModel
            if !present(vadPath) { warnings.append(.vadMissing) }
        }

        return LanguageSetup(
            rows: rows,
            mode: mode,
            detectionModelLabel: driverIsUsable
                ? (driverEntry?.label ?? (driverPath as NSString).lastPathComponent)
                : nil,
            warnings: warnings,
            isConfigured: !cs.languages.isEmpty)
    }

    private static func dedupe(_ codes: [String]) -> [String] {
        var seen = Set<String>()
        return codes.filter { seen.insert($0).inserted }
    }

    // MARK: Editing
    //
    // The two mutations Settings performs. Both return a complete `languages`
    // list, so the caller's job is a single assignment — there is no longer a
    // "and don't forget to also grow the whitelist" step to remember at each
    // call site (there used to be two such sites, each with its own copy).

    /// The current list *materialized*: an install that has never been
    /// configured is seeded from what's on disk, so an edit starts from exactly
    /// what the user is looking at rather than from an empty list that silently
    /// meant "everything".
    static func materialized(config: Config,
                             catalog: [CatalogEntry] = ModelCatalog.load(),
                             present: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> [LanguageSetting] {
        let cs = config.codeSwitch
        guard cs.languages.isEmpty else { return cs.languages }
        let installed = Models.installed(from: catalog,
                                         preferredKBVariant: cs.kbWhisperVariant,
                                         present: present)
        return installed.languages.map { LanguageSetting(code: $0) }
    }

    /// Add (or re-point) a language. Replacing an existing code keeps its
    /// position and prompt, so "change the model" doesn't reorder the list or
    /// silently drop a starter sentence.
    static func adding(_ code: String, model: String?,
                       to languages: [LanguageSetting]) -> [LanguageSetting] {
        var out = languages
        let code = code.trimmingCharacters(in: .whitespaces).lowercased()
        if let i = out.firstIndex(where: { $0.code == code }) {
            out[i].model = model
        } else {
            out.append(LanguageSetting(code: code, model: model))
        }
        return out
    }

    /// Remove a language. Returns nil when this would empty the list — the
    /// caller shows *why* instead of silently reverting the control, which is
    /// what the old checkbox did.
    static func removing(_ code: String, from languages: [LanguageSetting]) -> [LanguageSetting]? {
        let out = languages.filter { $0.code != code }
        return out.isEmpty ? nil : out
    }
}

extension LanguageSetup.Warning {
    /// The sentence shown in Settings. Written to say what breaks and what to
    /// do, not to name the internal flag.
    var message: String {
        switch self {
        case .noDetectionModel:
            return "No model here can tell languages apart. Ghostie will guess who's speaking what, and often get it wrong — add Whisper large-v3 to fix it."
        case .vadMissing:
            return "The Silero VAD model is missing. Ghostie needs it to find the pauses it splits languages on."
        case .modelMissing(let code):
            return "\(WhisperLanguages.displayName(code)) has a model picked out, but it isn't downloaded yet."
        case .noModelForLanguage(let code):
            return "Ghostie doesn't know a model for \(WhisperLanguages.displayName(code)). Pick one from Hugging Face."
        }
    }
}
