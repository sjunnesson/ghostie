import Foundation

/// Single source of truth for every model Ghostie can download: filename,
/// upstream URL, human label, approximate size for the UI. Anything that knows
/// where a model lives or how to fetch one reads from here.
///
/// Hash verification is not pinned: per design we trust Hugging Face's
/// `x-linked-etag` (a SHA256 of the file) captured at download time. The
/// captured etag is written to a `<filename>.meta` sidecar next to the model
/// so `ghostie doctor models` can re-verify on demand without a network round
/// trip.
struct Model {
    let filename: String
    let url: URL
    let label: String
    let approxBytes: Int64

    /// Resolved absolute path under `~/.ghostie/models/`.
    var destPath: String { "\(Config.modelsDir)/\(filename)" }

    /// Sidecar path that stores `{etag, size, downloadedAt}` after a
    /// successful download. Doctor uses this to re-verify on demand.
    var sidecarPath: String { destPath + ".meta" }
}

enum Models {

    static let baseEnglish = Model(
        filename: "ggml-base.en.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-base.en.bin")!,
        label: "Whisper base (English) · ~150 MB",
        approxBytes: 147_964_211
    )

    static let largeV3 = Model(
        filename: "ggml-large-v3-q5_0.bin",
        url: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin")!,
        label: "Whisper large-v3 (Q5) · ~1.1 GB",
        approxBytes: 1_081_140_203
    )

    static let sileroVAD = Model(
        filename: "ggml-silero-v5.1.2.bin",
        url: URL(string: "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin")!,
        label: "Silero VAD · ~900 KB",
        approxBytes: 885_098
    )

    /// KB-Whisper has multiple variants on different Hugging Face revisions.
    /// `subtitle` is HF-format only (no prebuilt GGML) and returns nil.
    static func kbWhisperLarge(variant: String) -> Model? {
        let rev: String
        switch variant {
        case "standard": rev = "main"
        case "strict":   rev = "strict"
        default:         return nil
        }
        return Model(
            filename: "ggml-kb-whisper-large-\(variant)-q5_0.bin",
            url: URL(string: "https://huggingface.co/KBLab/kb-whisper-large/resolve/\(rev)/ggml-model-q5_0.bin")!,
            label: "KB-Whisper-large (\(variant)) · ~1.1 GB",
            approxBytes: 1_081_140_203
        )
    }

    /// The set of models Ghostie actually needs given the current config.
    /// Drives "Download missing models", the doctor row list, and the headless
    /// `fetch-models` subcommand.
    static func required(for config: Config) -> [Model] {
        var out: [Model] = []
        if config.codeSwitch.enabled {
            if let kb = kbWhisperLarge(variant: config.codeSwitch.kbWhisperVariant) {
                out.append(kb)
            }
            out.append(largeV3)
            out.append(sileroVAD)
        } else {
            out.append(baseEnglish)
            out.append(sileroVAD)   // optional but recommended; doctor flags it as such
        }
        return out
    }
}

/// What we last knew about a successfully-downloaded model. Lives next to the
/// model as JSON (`<filename>.meta`). Doctor reads this; downloader writes it.
struct ModelSidecar: Codable {
    let etag: String        // SHA256 from Hugging Face's `x-linked-etag` header
    let size: Int64         // byte count at the time of the successful download
    let downloadedAt: Date

    static func read(_ path: String) -> ModelSidecar? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        return try? JSONDecoder.iso.decode(ModelSidecar.self, from: data)
    }

    func write(to path: String) {
        guard let data = try? JSONEncoder.iso.encode(self) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}

private extension JSONEncoder {
    static let iso: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
}

private extension JSONDecoder {
    static let iso: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
