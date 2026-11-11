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
