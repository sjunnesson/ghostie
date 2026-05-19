import Foundation

/// Downloads the code-switching speech models straight from Hugging Face into
/// `~/.ghostie/models/`, so a `.dmg` user with no terminal can set it up from
/// Settings. The variant→URL mapping and destination filenames are kept
/// identical to `scripts/setup.sh` and `CodeSwitchConfig.modelPath(for:)`.
final class ModelDownloader: NSObject, URLSessionDownloadDelegate {

    struct Item { let label: String; let url: URL; let dest: URL }

    enum DLError: LocalizedError {
        case subtitleUnavailable
        case http(Int, String)
        var errorDescription: String? {
            switch self {
            case .subtitleUnavailable:
                return "KB-Whisper ‘subtitle’ has no prebuilt whisper.cpp model upstream. Choose ‘standard’ or ‘strict’."
            case .http(let code, let label):
                return "\(label) download failed (HTTP \(code))."
            }
        }
    }

    /// The models needed for a KB variant + English (large-v3) + Silero VAD.
    /// `nil` ⇒ the variant has no prebuilt GGML (subtitle is HF-format only).
    static func items(variant: String) -> [Item]? {
        let kbRev: String
        switch variant {
        case "standard": kbRev = "main"      // default model lives on `main`
        case "strict":   kbRev = "strict"    // `strict` tag carries the GGML
        default:         return nil          // subtitle: no upstream GGML
        }
        let dir = Config.modelsDir
        func mk(_ label: String, _ s: String, _ file: String) -> Item {
            Item(label: label, url: URL(string: s)!,
                 dest: URL(fileURLWithPath: "\(dir)/\(file)"))
        }
        return [
            mk("KB-Whisper-large (\(variant)) · ~1.1 GB",
               "https://huggingface.co/KBLab/kb-whisper-large/resolve/\(kbRev)/ggml-model-q5_0.bin",
               "ggml-kb-whisper-large-\(variant)-q5_0.bin"),
            mk("whisper-large-v3 · ~1.1 GB",
               "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin",
               "ggml-large-v3-q5_0.bin"),
            mk("Silero VAD · ~1 MB",
               "https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v5.1.2.bin",
               "ggml-silero-v5.1.2.bin")
        ]
    }

    private var pending: [Item] = []
    private var current: Item?
    private var session: URLSession?
    private var onStatus: ((String) -> Void)?
    private var onFinish: ((Error?) -> Void)?
    private var finished = false
    private(set) var isRunning = false

    /// Files already present (non-trivially sized) are skipped.
    func start(_ items: [Item],
               status: @escaping (String) -> Void,
               finish: @escaping (Error?) -> Void) {
        onStatus = status; onFinish = finish
        finished = false; isRunning = true
        // Skip files already on disk. 200 KB floor ignores empty/partial
        // stubs while still keeping the ~0.9 MB Silero VAD model.
        pending = items.filter {
            !(FileManager.default.fileExists(atPath: $0.dest.path)
              && Self.size($0.dest) > 200_000)
        }
        let skipped = items.count - pending.count
        if skipped > 0 { post("\(skipped) model(s) already present — skipping.") }
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        next()
    }

    func cancel() {
        guard isRunning else { return }
        finished = true; isRunning = false
        session?.invalidateAndCancel(); session = nil
    }

    // MARK: Queue

    private func next() {
        guard !finished else { return }
        guard let item = pending.first else { complete(nil); return }
        current = item
        try? FileManager.default.createDirectory(
            at: item.dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        post("Downloading \(item.label)… 0%")
        session?.downloadTask(with: item.url).resume()
    }

    private func complete(_ err: Error?) {
        guard !finished else { return }
        finished = true; isRunning = false
        let cb = onFinish
        session?.finishTasksAndInvalidate(); session = nil
        DispatchQueue.main.async { cb?(err) }
    }

    private func post(_ s: String) {
        let cb = onStatus
        DispatchQueue.main.async { cb?(s) }
    }

    private static func size(_ u: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: u.path))?[.size] as? Int) ?? 0
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask,
                     didWriteData _: Int64, totalBytesWritten w: Int64,
                     totalBytesExpectedToWrite e: Int64) {
        guard let item = current else { return }
        func mb(_ b: Int64) -> String {
            b >= 1_000_000 ? "\(b / 1_000_000) MB" : "\(max(0, b) / 1000) KB"
        }
        if e > 0 {
            post("Downloading \(item.label)… "
                 + "\(Int(Double(w) / Double(e) * 100))%  (\(mb(w))/\(mb(e)))")
        } else {
            post("Downloading \(item.label)… \(mb(w))")
        }
    }

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask,
                     didFinishDownloadingTo loc: URL) {
        guard let item = current else { return }
        if let http = t.response as? HTTPURLResponse, http.statusCode != 200 {
            complete(DLError.http(http.statusCode, item.label)); return
        }
        let fm = FileManager.default
        do {
            try? fm.removeItem(at: item.dest)
            try fm.moveItem(at: loc, to: item.dest)
        } catch { complete(error); return }
        if !pending.isEmpty { pending.removeFirst() }
        post("✓ \(item.label) — done")
        next()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask,
                     didCompleteWithError error: Error?) {
        // Success is handled in didFinishDownloadingTo; only surface failures.
        if let error = error, !finished { complete(error) }
    }
}
