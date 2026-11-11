import Foundation

/// Which transducer models exist, where they come from, and which are on disk.
///
/// Two models are known by name today — Klang Pianissimo for Swedish and for
/// Danish — and Klang has said more European languages will follow. Both
/// published models are the same thing in the same shape: a repo
/// `KlangAI/pianissimo-<code>-onnx` holding the same four file names. So the
/// catalog is that *convention*, with the known languages as verified
/// instances of it, and a language Klang ships next needs no release of
/// Ghostie:
///
///   * `ghostie fetch-models --transducer no` asks for
///     `KlangAI/pianissimo-no-onnx` and installs it if it is there (a clear
///     "not published" if it is not);
///   * any folder under `~/.ghostie/models/` that holds the four files and is
///     named `<name>-<code>-onnx` is an installed model for `<code>`, however
///     it got there.
///
/// Nothing here makes a language *active*: a model is used only for a language
/// the call is already set up for (`CodeSwitchConfig.effectiveLanguages`).
enum TransducerCatalog {

    struct Entry: Equatable {
        /// ISO code the model decodes.
        let language: String
        /// Folder under `~/.ghostie/models/`.
        let directory: String
        /// Hugging Face repo the files are fetched from.
        let repo: String
        let label: String
        /// False for a language reached only through the naming convention:
        /// nobody has run it here, and the download is the first proof the
        /// repo exists.
        let verified: Bool
        /// Byte counts for the skip-if-present check; 0 where unknown, in
        /// which case the downloader goes by its sidecar.
        var sizes: [String: Int64] = [:]
    }

    /// The four files, with what each is for the download log.
    static let files: [(name: String, role: String)] = [
        (TransducerModel.encoderNames[0], "encoder"),
        (TransducerModel.decoderNames[0], "decoder"),
        (TransducerModel.featuresName, "features"),
        (TransducerModel.vocabName, "vocabulary"),
    ]

    /// Models that have been fetched and run. Sizes from the repos as of
    /// 2026-11-11; the encoder, features and vocabulary are byte-for-byte the
    /// same size across languages (one architecture, one tokenizer).
    static let known: [Entry] = [
        klang("sv", decoderBytes: 30_025_652, verified: true),
        klang("da", decoderBytes: 53_639_765, verified: true),
        parakeetEnglish,
    ]

    /// English: NVIDIA Parakeet TDT 0.6B v3 itself — the model the Klang ones
    /// are fine-tuned from — in the community int8 ONNX export with the same
    /// four file names (CC BY 4.0). It is multilingual underneath (25 European
    /// languages, language chosen by the audio), which is exactly what a
    /// *first* decode wants: it writes Swedish speech down as Swedish, so the
    /// text still says which stretches belong to another model.
    static let parakeetEnglish = Entry(
        language: "en",
        directory: "parakeet-tdt-0.6b-v3-en-onnx",
        repo: "istupakov/parakeet-tdt-0.6b-v3-onnx",
        label: "NVIDIA Parakeet TDT v3 · English",
        verified: true,
        sizes: [TransducerModel.encoderNames[0]: 652_183_999,
                TransducerModel.decoderNames[0]: 18_202_004,
                TransducerModel.featuresName: 139_764,
                TransducerModel.vocabName: 93_939])

    /// Klang's entry for `language` under the naming convention.
    static func klang(_ language: String, decoderBytes: Int64 = 0, verified: Bool = false) -> Entry {
        let code = language.lowercased()
        return Entry(language: code,
                     directory: "pianissimo-\(code)-onnx",
                     repo: "KlangAI/pianissimo-\(code)-onnx",
                     label: "Klang Pianissimo · \(WhisperLanguages.displayName(code))",
                     verified: verified,
                     sizes: [TransducerModel.encoderNames[0]: verified ? 630_313_965 : 0,
                             TransducerModel.decoderNames[0]: decoderBytes,
                             TransducerModel.featuresName: verified ? 138_824 : 0,
                             TransducerModel.vocabName: verified ? 93_939 : 0])
    }

    /// The entry to fetch for `language`: the known one, else the convention.
    static func entry(for language: String) -> Entry {
        let code = language.lowercased()
        return known.first { $0.language == code } ?? klang(code)
    }

    /// A plausible language code — what `fetch-models --transducer <x>` and a
    /// folder name are allowed to mean.
    static func isLanguageCode(_ text: String) -> Bool {
        (2...3).contains(text.count) && text.allSatisfy { $0.isASCII && $0.isLowercase }
    }

    /// The downloads that make up `entry`.
    static func models(for entry: Entry) -> [Model] {
        files.map { file in
            Model(filename: "\(entry.directory)/\(file.name)",
                  url: URL(string: "https://huggingface.co/\(entry.repo)/resolve/main/\(file.name)")!,
                  label: "\(entry.label) · \(file.role)",
                  approxBytes: entry.sizes[file.name] ?? 0)
        }
    }

    /// The language a model folder decodes, from its name alone: a known
    /// folder, else anything shaped `<name>-<code>-onnx`.
    static func language(ofDirectory name: String) -> String? {
        if let entry = known.first(where: { $0.directory == name }) { return entry.language }
        let parts = name.split(separator: "-").map(String.init)
        guard parts.count >= 3, parts.last == "onnx",
              isLanguageCode(parts[parts.count - 2]) else { return nil }
        return parts[parts.count - 2]
    }

    /// Installed model folders by language. The disk is the switch, as for
    /// every other model. Two folders for one language: the known name wins,
    /// then the alphabetically first, so the choice never depends on the order
    /// the filesystem lists them in. `list` and `present` are injected for the
    /// selftest.
    static func installed(
        in modelsDir: String = Config.modelsDir,
        list: (String) -> [String] = { (try? FileManager.default.contentsOfDirectory(atPath: $0)) ?? [] },
        present: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String: String] {
        var out: [String: String] = [:]
        let knownNames = Set(known.map(\.directory))
        let names = list(modelsDir).sorted {
            (knownNames.contains($0) ? 0 : 1, $0) < (knownNames.contains($1) ? 0 : 1, $1)
        }
        for name in names {
            guard let language = language(ofDirectory: name), out[language] == nil,
                  TransducerModel.files(at: "\(modelsDir)/\(name)", present: present) != nil
            else { continue }
            out[language] = "\(modelsDir)/\(name)"
        }
        return out
    }

    /// Which model decodes the call first: the dominant language's when it
    /// has one — most of the audio is then decoded once and kept — else the
    /// first of the call's languages that does.
    static func home(languages: [String], dominant: String, installed: [String: String]) -> String? {
        if languages.contains(dominant), installed[dominant] != nil { return dominant }
        return languages.first { installed[$0] != nil }
    }
}

/// Which transducer models an install should have and does not — what the app
/// fetches in the background so the faster path arrives without anyone
/// opening Settings.
enum TransducerAutoFetch {

    /// Room to leave on the disk beyond the download itself.
    static let headroomBytes: Int64 = 5_000_000_000

    /// The known models to fetch for `languages`, in that order.
    ///
    /// Nothing when the feature is off, and nothing when the ONNX Runtime
    /// cannot load — 650 MB that this Mac could never run is not a favour.
    /// Only `known` models: a language reached by naming convention alone is
    /// fetched when somebody asks for it by name, never on a guess. A model
    /// that would leave the disk under `headroomBytes` waits.
    static func wanted(enabled: Bool, runtimeAvailable: Bool, languages: [String],
                       installed: [String: String], freeBytes: Int64?) -> [TransducerCatalog.Entry] {
        guard enabled, runtimeAvailable else { return [] }
        var free = freeBytes
        var out: [TransducerCatalog.Entry] = []
        for language in languages where installed[language] == nil {
            guard let entry = TransducerCatalog.known.first(where: { $0.language == language }) else { continue }
            let size = entry.sizes.values.reduce(0, +)
            if let available = free {
                guard available - size >= headroomBytes else { continue }
                free = available - size
            }
            out.append(entry)
        }
        return out
    }

    /// `wanted` for this Mac as it is now.
    static func wanted(config: Config) -> [TransducerCatalog.Entry] {
        let installedModels = Models.installed(preferredKBVariant: config.codeSwitch.kbWhisperVariant)
        let attrs = try? FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
        return wanted(enabled: config.codeSwitch.transducerDecode,
                      runtimeAvailable: ORTRuntime.shared != nil,
                      languages: config.codeSwitch.effectiveLanguages(installed: installedModels),
                      installed: TransducerCatalog.installed(),
                      freeBytes: (attrs?[.systemFreeSize] as? NSNumber)?.int64Value)
    }
}

/// How the transducer path is put into words in Settings. One place, pure, so
/// the row, the summary line and the model picker cannot tell three stories —
/// and so `selftest` can read them.
///
/// It exists because v1.14.0 shipped the path with a single toggle to show for
/// it: the Swedish row still read "KB-Whisper-large", the model picker still
/// asked "which model should decode this language", and the person who built
/// the feature opened Settings and asked whether the update had installed.
enum TransducerPresentation {

    /// What the fast model is doing for one language.
    enum State: Equatable {
        /// Installed and in use; the associated value is the model's name.
        case active(String)
        /// Known, wanted, not on disk yet — the background fetch is on it.
        case downloading(String)
        /// On disk, but "Faster transcription" is off.
        case off(String)
        /// Installed and wanted, but this build cannot load the runtime.
        case unavailable(String)
        /// No fast model exists for this language.
        case none
    }

    /// A model's short name: "Klang Pianissimo", "NVIDIA Parakeet".
    static func name(language: String, directory: String?) -> String {
        if let known = TransducerCatalog.known.first(where: { $0.language == language }),
           directory == nil || (directory! as NSString).lastPathComponent == known.directory {
            return language == "en" ? "NVIDIA Parakeet" : "Klang Pianissimo"
        }
        if let directory {
            let folder = (directory as NSString).lastPathComponent
            return folder.hasPrefix("pianissimo-") ? "Klang Pianissimo" : folder
        }
        return "Klang Pianissimo"
    }

    static func state(language: String, enabled: Bool, runtime: Bool,
                      installed: [String: String]) -> State {
        if let directory = installed[language] {
            let model = name(language: language, directory: directory)
            if !enabled { return .off(model) }
            return runtime ? .active(model) : .unavailable(model)
        }
        guard enabled, runtime,
              TransducerCatalog.known.contains(where: { $0.language == language }) else { return .none }
        return .downloading(name(language: language, directory: nil))
    }

    /// `state` for this Mac as it is now.
    static func state(language: String, config: Config) -> State {
        state(language: language, enabled: config.codeSwitch.transducerDecode,
              runtime: ORTRuntime.shared != nil, installed: TransducerCatalog.installed())
    }

    /// The language row's one line: who transcribes it, and who stands behind.
    /// `whisper` is the row's whisper model by name alone; `roles` is what the
    /// row used to say about it, which is only still true when whisper is the
    /// one doing the work.
    static func rowSubtitle(_ state: State, whisper: String, roles: String) -> String {
        switch state {
        case .active(let model):
            return "Transcribed by \(model) · \(whisper) is the fallback"
        case .downloading(let model):
            return "\(roles) · \(model) is downloading and takes over when it arrives"
        case .off(let model):
            return "\(roles) · \(model) is installed, but Faster transcription is off"
        case .unavailable(let model):
            return "\(roles) · \(model) is installed, but this build cannot run it"
        case .none:
            return roles
        }
    }

    /// The row's badge when the fast model is the one at work.
    static func rowBadge(_ state: State) -> String? {
        if case .active = state { return "Fast" }
        return nil
    }

    /// The model picker's opening line for a language. The picker only ever
    /// lists whisper models; when another model does the transcribing, that
    /// has to be the first thing it says.
    static func pickerLead(_ state: State, languageName: String) -> String {
        switch state {
        case .active(let model):
            return "\(model) transcribes \(languageName). The model chosen here is the Whisper fallback: used if \(model) cannot run, and when Faster transcription is off."
        case .downloading(let model):
            return "\(model) is downloading and will transcribe \(languageName) once it arrives. Until then, and as the fallback after, Ghostie uses the Whisper model chosen here."
        case .off, .unavailable, .none:
            return "Which model should decode this language."
        }
    }

    /// How the whole setup transcribes, for the summary line under the
    /// languages: a title and one or two short sentences. nil leaves the
    /// caller's own (acoustic) wording in place. The rows above already name
    /// each model, so this says only *how* — it has two lines to do it in.
    static func mode(languages: [String], states: [String: State],
                     displayName: (String) -> String) -> (title: String, detail: String)? {
        let fast = languages.filter { if case .active? = states[$0] { return true }; return false }
        guard !fast.isEmpty else { return nil }
        func list(_ items: [String]) -> String { ListFormatter.localizedString(byJoining: items) }
        if languages.count == 1 {
            let name = displayName(languages[0])
            return ("One language — \(name), transcribed fast",
                    "Whisper takes over if a call turns out not to be in \(name).")
        }
        if let pair = TranscriptRouter.lookalikes(in: languages) {
            return ("\(languages.count) languages, told apart by ear",
                    "\(displayName(pair.0)) and \(displayName(pair.1)) read too alike on paper, so Ghostie listens for the language first. The fast models still do the transcribing.")
        }
        let rest = languages.filter { !fast.contains($0) }
        let tail = rest.isEmpty ? "" : " \(list(rest.map(displayName))) \(rest.count == 1 ? "goes" : "go") to Whisper."
        return ("\(languages.count) languages, told apart by what was said",
                "Each track is transcribed first, and the words show where the language changes.\(tail)")
    }
}
