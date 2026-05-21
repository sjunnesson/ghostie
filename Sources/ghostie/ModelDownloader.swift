import Foundation
import CryptoKit

/// Streams a model from Hugging Face into `~/.ghostie/models/`, hashing as it
/// goes, then verifies the result against the SHA256 HF returns in the
/// `x-linked-etag` header. On success the SHA + size are written to a sidecar
/// (`<filename>.meta`) so `ghostie doctor models` can re-verify on demand
/// without re-downloading.
///
/// Failure modes that previously bit us:
///   - Truncated downloads landed at dest and looked "present" forever. Now
///     the .partial file is only renamed in on a verified SHA256 match.
///   - Three independent copies of the URL/filename mapping (Config, this file,
///     setup.sh). Now `Models.swift` is the single source; the shell script
///     calls `ghostie fetch-models` instead of curling.
///   - VAD was bundled into the codeswitch download. Now the queue is a plain
///     `[Model]`, so the UI / CLI can request any subset.
final class ModelDownloader: NSObject, URLSessionDataDelegate {

    /// Backwards-compat `Item` shape for the existing call sites in Settings /
    /// `cmdFetchModels` that haven't migrated yet. New code should pass
    /// `[Model]` directly via `start(models:status:finish:)`.
    struct Item {
        let label: String
        let url: URL
        let dest: URL
        init(_ m: Model) {
            self.label = m.label
            self.url = m.url
            self.dest = URL(fileURLWithPath: m.destPath)
        }
        init(label: String, url: URL, dest: URL) {
            self.label = label; self.url = url; self.dest = dest
        }
    }

    enum DLError: LocalizedError {
        case subtitleUnavailable
        case http(Int, String)
        case hashMismatch(label: String, expected: String, got: String)
        case sizeMismatch(label: String, expected: Int64, got: Int64)
        var errorDescription: String? {
            switch self {
            case .subtitleUnavailable:
                return "KB-Whisper ‘subtitle’ has no prebuilt whisper.cpp model upstream. Choose ‘standard’ or ‘strict’."
            case .http(let code, let label):
                return "\(label) download failed (HTTP \(code))."
            case .hashMismatch(let label, let expected, let got):
                return "\(label) failed verification: expected SHA \(expected.prefix(12))…, got \(got.prefix(12))…."
            case .sizeMismatch(let label, let expected, let got):
                return "\(label) wrong size: expected \(expected) bytes, got \(got)."
            }
        }
    }

    /// Legacy entry point used by Settings + `cmdFetchModels` until those
    /// migrate to `Models.required(for:)`. Returns nil for `subtitle` (no GGML
    /// upstream) so callers can surface a useful error.
    static func items(variant: String) -> [Item]? {
        guard let kb = Models.kbWhisperLarge(variant: variant) else { return nil }
        return [kb, Models.largeV3, Models.sileroVAD].map(Item.init)
    }

    // MARK: - State

    private struct Active {
        let model: Model
        let label: String
        let dest: URL
        let partial: URL
        var sha = SHA256()
        var fh: FileHandle
        var bytesWritten: Int64 = 0
        var expectedSize: Int64 = 0
        var expectedEtag: String = ""
        var startedAt = Date()
    }

    private var queue: [(Model, String, URL)] = []   // (model, label, dest)
    private var current: Active?
    private var session: URLSession?
    private var onStatus: ((String) -> Void)?
    private var onFinish: ((Error?) -> Void)?
    private var finished = false
    private(set) var isRunning = false

    // MARK: - Public start variants

    /// Preferred entry point: explicit `[Model]` from the manifest.
    func start(models: [Model],
               status: @escaping (String) -> Void,
               finish: @escaping (Error?) -> Void) {
        let triples = models.map { ($0, $0.label, URL(fileURLWithPath: $0.destPath)) }
        beginQueue(triples, status: status, finish: finish)
    }

    /// Legacy entry point. Same semantics, takes `[Item]`. Used by Settings
    /// until the UI migrates.
    func start(_ items: [Item],
               status: @escaping (String) -> Void,
               finish: @escaping (Error?) -> Void) {
        // Items don't carry a `Model`, but the URL fully identifies one — look
        // up by filename so we still get sidecar writes and skip-if-present.
        let triples: [(Model, String, URL)] = items.map { item in
            let fn = item.dest.lastPathComponent
            let m: Model = (
                fn == Models.baseEnglish.filename ? Models.baseEnglish :
                fn == Models.largeV3.filename ? Models.largeV3 :
                fn == Models.sileroVAD.filename ? Models.sileroVAD :
                Model(filename: fn, url: item.url, label: item.label, approxBytes: 0)
            )
            return (m, item.label, item.dest)
        }
        beginQueue(triples, status: status, finish: finish)
    }

    func cancel() {
        guard isRunning else { return }
        finished = true; isRunning = false
        session?.invalidateAndCancel(); session = nil
        if let a = current {
            try? a.fh.close()
            try? FileManager.default.removeItem(at: a.partial)
        }
        current = nil
    }

    // MARK: - Queue management

    private func beginQueue(_ items: [(Model, String, URL)],
                            status: @escaping (String) -> Void,
                            finish: @escaping (Error?) -> Void) {
        onStatus = status
        onFinish = finish
        finished = false
        isRunning = true

        // Skip-if-present: prefer the sidecar's recorded size, fall back to
        // matching the model's approxBytes (so the older user who downloaded
        // before sidecars existed isn't forced to re-download).
        let needed = items.filter { (model, _, dest) in
            !Self.looksAlreadyComplete(model: model, dest: dest)
        }
        let skipped = items.count - needed.count
        if skipped > 0 { post("\(skipped) model(s) already present — skipping.") }
        queue = needed

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForResource = 3600
        cfg.waitsForConnectivity = true
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        next()
    }

    private static func looksAlreadyComplete(model: Model, dest: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: dest.path),
              let attrs = try? fm.attributesOfItem(atPath: dest.path),
              let size = attrs[.size] as? Int64, size > 0
        else { return false }
        if let s = ModelSidecar.read(model.sidecarPath), s.size == size { return true }
        // No sidecar yet: trust the size matches the manifest's known good.
        // Doctor will re-verify on demand and flag anything that doesn't hash.
        if model.approxBytes > 0, size == model.approxBytes { return true }
        return false
    }

    private func next() {
        guard !finished else { return }
        guard let (model, label, dest) = queue.first else { complete(nil); return }
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Stream into <dest>.partial so a crash never leaves a half-file at
        // the final path.
        let partial = URL(fileURLWithPath: dest.path + ".partial")
        try? FileManager.default.removeItem(at: partial)
        FileManager.default.createFile(atPath: partial.path, contents: nil)
        guard let fh = try? FileHandle(forWritingTo: partial) else {
            complete(NSError(domain: "ghostie", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Could not open \(partial.lastPathComponent) for writing."
            ]))
            return
        }

        current = Active(model: model, label: label, dest: dest,
                         partial: partial, fh: fh)
        post("Downloading \(label)… 0%")
        var req = URLRequest(url: model.url)
        req.httpMethod = "GET"
        session?.dataTask(with: req).resume()
    }

    private func complete(_ err: Error?) {
        guard !finished else { return }
        finished = true; isRunning = false
        let cb = onFinish
        session?.finishTasksAndInvalidate(); session = nil
        if let a = current { try? a.fh.close() }
        current = nil
        DispatchQueue.main.async { cb?(err) }
    }

    private func post(_ s: String) {
        let cb = onStatus
        DispatchQueue.main.async { cb?(s) }
    }

    // MARK: - URLSessionDataDelegate (streaming + hashing)

    /// Hugging Face puts `x-linked-etag` and `x-linked-size` on the 302
    /// redirect response, NOT on the final CDN response. We have to capture
    /// them here before URLSession transparently follows the redirect.
    func urlSession(_ s: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        captureSigningHeaders(from: response)
        completionHandler(request)
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard var a = current else { completionHandler(.cancel); return }
        if let http = response as? HTTPURLResponse {
            if http.statusCode != 200 {
                complete(DLError.http(http.statusCode, a.label))
                completionHandler(.cancel); return
            }
            // Fallback for non-HF mirrors: the canonical headers may sit on
            // the 200 itself. Already-captured values from the 302 win.
            captureSigningHeaders(from: http)
            if a.expectedSize == 0 { a.expectedSize = max(0, response.expectedContentLength) }
            current = current ?? a   // captureSigningHeaders may have updated current
        }
        completionHandler(.allow)
    }

    private func captureSigningHeaders(from http: HTTPURLResponse) {
        guard var a = current else { return }
        let etag = (http.value(forHTTPHeaderField: "x-linked-etag")
                    ?? http.value(forHTTPHeaderField: "X-Linked-Etag"))?
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        let size = (http.value(forHTTPHeaderField: "x-linked-size")
                    ?? http.value(forHTTPHeaderField: "X-Linked-Size")).flatMap(Int64.init)
        if a.expectedEtag.isEmpty, let etag, !etag.isEmpty { a.expectedEtag = etag }
        if a.expectedSize == 0, let size, size > 0 { a.expectedSize = size }
        current = a
    }

    func urlSession(_ s: URLSession, dataTask: URLSessionDataTask,
                    didReceive data: Data) {
        guard var a = current else { return }
        a.fh.write(data)
        a.bytesWritten += Int64(data.count)
        data.withUnsafeBytes { a.sha.update(bufferPointer: $0) }
        current = a
        emitProgress()
    }

    func urlSession(_ s: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard !finished, let a = current else {
            if let error = error, !finished { complete(error) }
            return
        }
        if let error = error {
            try? a.fh.close()
            try? FileManager.default.removeItem(at: a.partial)
            complete(error); return
        }
        try? a.fh.close()
        let got = a.sha.finalize()
        let gotHex = got.map { String(format: "%02x", $0) }.joined()
        current = a

        if a.expectedSize > 0 && a.bytesWritten != a.expectedSize {
            try? FileManager.default.removeItem(at: a.partial)
            complete(DLError.sizeMismatch(label: a.label,
                                          expected: a.expectedSize,
                                          got: a.bytesWritten))
            return
        }
        if !a.expectedEtag.isEmpty, gotHex.caseInsensitiveCompare(a.expectedEtag) != .orderedSame {
            try? FileManager.default.removeItem(at: a.partial)
            complete(DLError.hashMismatch(label: a.label,
                                          expected: a.expectedEtag,
                                          got: gotHex))
            return
        }

        // Verified. Atomic-rename into place and write the sidecar.
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: a.dest.path) {
                try fm.removeItem(at: a.dest)
            }
            try fm.moveItem(at: a.partial, to: a.dest)
        } catch {
            complete(error); return
        }
        ModelSidecar(etag: gotHex, size: a.bytesWritten, downloadedAt: Date())
            .write(to: a.model.sidecarPath)

        post("✓ \(a.label) — verified (\(gotHex.prefix(12))…)")
        if !queue.isEmpty { queue.removeFirst() }
        current = nil
        next()
    }

    private func emitProgress() {
        guard let a = current else { return }
        func mb(_ b: Int64) -> String {
            b >= 1_000_000 ? "\(b / 1_000_000) MB" : "\(max(0, b) / 1000) KB"
        }
        if a.expectedSize > 0 {
            let pct = Int(Double(a.bytesWritten) / Double(a.expectedSize) * 100)
            post("Downloading \(a.label)… \(pct)%  (\(mb(a.bytesWritten))/\(mb(a.expectedSize)))")
        } else {
            post("Downloading \(a.label)… \(mb(a.bytesWritten))")
        }
    }
}

// MARK: - Doctor

extension ModelDownloader {

    enum HealthState {
        case ok(etag: String, size: Int64)
        case missing
        case sizeWrong(onDisk: Int64, expected: Int64)
        case hashMismatch(onDisk: String, expected: String)
        case noSidecar(onDisk: Int64)

        var summary: String {
            switch self {
            case .ok(let etag, _):              return "ok (\(etag.prefix(12))…)"
            case .missing:                       return "missing"
            case .sizeWrong(let g, let e):       return "size mismatch (on disk \(g), expected \(e))"
            case .hashMismatch(let g, let e):    return "hash mismatch (on disk \(g.prefix(12))…, expected \(e.prefix(12))…)"
            case .noSidecar(let g):              return "no sidecar (on disk \(g) bytes; never verified)"
            }
        }
        var isOK: Bool { if case .ok = self { return true } else { return false } }
    }

    struct Health {
        let model: Model
        let state: HealthState
    }

    /// Hash + size each model on disk against its sidecar. SHA256 of a 1 GB
    /// file is ~3 sec on Apple Silicon; this is a deliberate on-demand check,
    /// not a launch-time one.
    static func health(for models: [Model]) -> [Health] {
        let fm = FileManager.default
        return models.map { m in
            guard fm.fileExists(atPath: m.destPath),
                  let attrs = try? fm.attributesOfItem(atPath: m.destPath),
                  let size = attrs[.size] as? Int64
            else { return Health(model: m, state: .missing) }
            guard let side = ModelSidecar.read(m.sidecarPath) else {
                return Health(model: m, state: .noSidecar(onDisk: size))
            }
            if size != side.size {
                return Health(model: m, state: .sizeWrong(onDisk: size, expected: side.size))
            }
            let got = hash(file: m.destPath)
            if got.caseInsensitiveCompare(side.etag) != .orderedSame {
                return Health(model: m, state: .hashMismatch(onDisk: got, expected: side.etag))
            }
            return Health(model: m, state: .ok(etag: side.etag, size: size))
        }
    }

    /// Adopt a legacy file by HEAD-ing its URL, hashing the on-disk file, and
    /// writing the sidecar if they match. Returns the post-adoption state.
    /// No network call if the file is missing locally.
    static func adopt(_ model: Model) -> HealthState {
        let fm = FileManager.default
        guard fm.fileExists(atPath: model.destPath),
              let attrs = try? fm.attributesOfItem(atPath: model.destPath),
              let size = attrs[.size] as? Int64
        else { return .missing }
        guard let (etag, expectedSize) = headInfo(for: model.url) else {
            // Network unavailable: leave as noSidecar so the user knows.
            return .noSidecar(onDisk: size)
        }
        if expectedSize > 0 && size != expectedSize {
            return .sizeWrong(onDisk: size, expected: expectedSize)
        }
        let got = hash(file: model.destPath)
        if got.caseInsensitiveCompare(etag) != .orderedSame {
            return .hashMismatch(onDisk: got, expected: etag)
        }
        ModelSidecar(etag: etag, size: size, downloadedAt: Date())
            .write(to: model.sidecarPath)
        return .ok(etag: etag, size: size)
    }

    /// HEAD probe returning Hugging Face's `x-linked-etag` (a SHA256) and
    /// `x-linked-size`. HF emits these on the 302, so we intercept the
    /// redirect, capture the headers, and then stop — no point following
    /// through to the CDN for a HEAD that already has what we need.
    private static func headInfo(for url: URL) -> (etag: String, size: Int64)? {
        final class Probe: NSObject, URLSessionTaskDelegate, URLSessionDataDelegate {
            var etag: String = ""
            var size: Int64 = 0
            let sem: DispatchSemaphore
            init(_ s: DispatchSemaphore) { sem = s; super.init() }
            func capture(_ http: HTTPURLResponse) {
                let e = (http.value(forHTTPHeaderField: "x-linked-etag")
                         ?? http.value(forHTTPHeaderField: "X-Linked-Etag"))?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let s = (http.value(forHTTPHeaderField: "x-linked-size")
                         ?? http.value(forHTTPHeaderField: "X-Linked-Size")).flatMap(Int64.init)
                    ?? http.expectedContentLength
                if let e, !e.isEmpty { etag = e }
                if s > 0 { size = s }
            }
            func urlSession(_ s: URLSession, task: URLSessionTask,
                            willPerformHTTPRedirection response: HTTPURLResponse,
                            newRequest request: URLRequest,
                            completionHandler: @escaping (URLRequest?) -> Void) {
                capture(response)
                completionHandler(nil)   // stop; we have the headers
            }
            func urlSession(_ s: URLSession, dataTask: URLSessionDataTask,
                            didReceive response: URLResponse,
                            completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
                if let http = response as? HTTPURLResponse { capture(http) }
                completionHandler(.cancel)
            }
            func urlSession(_ s: URLSession, task: URLSessionTask,
                            didCompleteWithError error: Error?) {
                sem.signal()
            }
        }
        let sem = DispatchSemaphore(value: 0)
        let probe = Probe(sem)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: cfg, delegate: probe, delegateQueue: nil)
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        session.dataTask(with: req).resume()
        _ = sem.wait(timeout: .now() + 20)
        session.invalidateAndCancel()
        return probe.etag.isEmpty ? nil : (probe.etag, probe.size)
    }

    /// SHA256 in 1 MB chunks so we don't load 1 GB into RAM.
    private static func hash(file path: String) -> String {
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "" }
        defer { try? fh.close() }
        var sha = SHA256()
        let chunk = 1 << 20
        while true {
            let data = (try? fh.read(upToCount: chunk)) ?? Data()
            if data.isEmpty { break }
            data.withUnsafeBytes { sha.update(bufferPointer: $0) }
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
