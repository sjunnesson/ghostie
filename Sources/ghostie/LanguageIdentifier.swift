import Foundation

/// The one shape both the LID and the smoother keep re-deriving: put `mass`
/// on `top`, spread the residual `(1 − mass)` uniformly over the rest, return
/// it as log-probabilities. Having a single definition (rather than four
/// near-copies with subtly different clamp bounds) means the smoother and the
/// identifier can't drift into disagreeing about the same distribution — the
/// kind of mismatch that re-routes audio to the wrong model.
enum LogProb {
    /// `over` is the language set the distribution covers. When `top` ∈ `over`
    /// (the normal case) it gets `mass` (clamped to `clamp`) and the others
    /// share the residual; when `top` ∉ `over` the result is uniform.
    static func skewed(toward top: String, mass: Double, over langs: [String],
                       clamp: ClosedRange<Double> = 0.001...0.999) -> [String: Double] {
        let c = min(clamp.upperBound, max(clamp.lowerBound, mass))
        let n = max(1, langs.count)
        var out: [String: Double] = [:]
        if langs.contains(top), n > 1 {
            let spread = (1 - c) / Double(n - 1)
            for l in langs { out[l] = Foundation.log(l == top ? c : spread) }
        } else if langs.contains(top) {
            out[top] = Foundation.log(c)
        } else {
            let u = Foundation.log(1.0 / Double(n))
            for l in langs { out[l] = u }
        }
        return out
    }
}

/// The seam between "segment audio into language regions" and "ask a model
/// which language a piece of audio is in".
///
/// Lifting this out of `LanguageSegmenter` lets us swap whisper-as-LID
/// (today's path, accurate only on ≥ 1.5 s segments) for a dedicated
/// short-audio identifier (VoxLingua107 / TitaNet, see `code-switching-v2.md`)
/// without rewriting the segmenter's orchestration: per-segment slicing,
/// nordic-look-alike mapping, whitelist enforcement, and the unknown floor
/// stay in `LanguageSegmenter` because they are application policy, not
/// LID-model details.
///
/// Concrete identifiers are owned by themselves — binary paths, model
/// handles, ONNX sessions, scratch directories — so the segmenter doesn't
/// need to know which family of model is answering.
protocol LanguageIdentifier {
    /// Posterior over `restrict` for one audio window, returned as
    /// **log-probabilities** that sum to 1 in linear space (the same shape
    /// `Smoother` consumes via `LanguageDetection.logprobs`). The top label
    /// is the entry with the largest log-prob; confidence is `exp(top)`.
    ///
    /// Implementations that natively return only a top-1 + confidence
    /// spread the residual mass `(1 − confidence)` uniformly over the rest
    /// of `restrict`, matching `LanguageSegmenter.mapped(lang:p:)`'s shape.
    ///
    /// `pcm` is canonical 16 kHz mono Int16-LE PCM bytes (Ghostie's invariant —
    /// see `WavWriter` / `AudioStitcher.readPCM`). `restrict` must be
    /// non-empty; the identifier may emit keys outside `restrict` only if it
    /// also re-normalizes back inside `restrict`. Errors propagate so the
    /// segmenter's `unknownDetection` floor can absorb a single failure
    /// without aborting the whole call.
    func identify(pcm: Data,
                  sampleRateHz: Int,
                  restrict: [String]) throws -> [String: Double]

    /// One-line description for `ghostie doctor` so users can see which
    /// LID family is active without grepping logs. Example: "whisper-cli
    /// language head (large-v3-q5_0)" or "VoxLingua107 ECAPA-TDNN (ONNX)".
    var description: String { get }

    /// Release any resident resources the identifier holds (processes,
    /// sockets, sessions). Stateless identifiers (WhisperLID, test stubs)
    /// inherit the default no-op below; a resident identifier
    /// (`ServerWhisperLID`) tears its server down here. The owner of the
    /// identifier for the duration of a call must invoke this exactly once
    /// when detect work finishes, success or throw — see the `defer` in
    /// `CodeSwitchTranscriber.transcribeBoth`.
    func shutdown()
}

extension LanguageIdentifier {
    /// Default no-op so existing identifiers and test stubs conform unchanged.
    func shutdown() {}
}

/// Lets the segmenter tell a *structural* identifier failure (model/binary/
/// framework missing — every segment will fail the same way) apart from a
/// per-segment "couldn't tell" (unparseable output, off-whitelist guess). The
/// segmenter rethrows the former so the call backlogs and retries cleanly,
/// and absorbs the latter into the `unknown` floor. Errors that don't conform
/// are treated as soft (per-segment) by default.
protocol ClassifiableLIDError: Error {
    var isStructural: Bool { get }
}

// MARK: - WhisperLID — today's path, refactored behind the protocol

/// Per-segment language ID via the whisper-cli `--detect-language` head.
/// Accurate only on ≥ ~1.5 s audio — the segmenter still enforces the
/// `minDetectMs` floor when this is the active identifier. Slices to a temp
/// WAV per call because `-dl` ignores `--offset-t`/`--duration` in the
/// shipped whisper-cli builds (verified; see `code-switching.md` Phase 2 and
/// the "Implementation corrections" section).
struct WhisperLID: LanguageIdentifier {
    let binary: String
    let model: String
    /// Maps the raw whisper top label before whitelist enforcement. Used by
    /// `LanguageSegmenter` to fold `no`/`nb`/`nn`/`da` → `sv` (KB-Whisper /
    /// whisper's lang head confuse Nordic languages on short Swedish audio)
    /// without making this struct aware of the sv-specific policy. Identity
    /// by default — call sites that don't care pass nothing.
    let remapTop: (String) -> String

    init(binary: String,
         model: String,
         remapTop: @escaping (String) -> String = { $0 }) {
        self.binary = binary
        self.model = model
        self.remapTop = remapTop
    }

    var description: String {
        "whisper-cli language head (\((model as NSString).lastPathComponent))"
    }

    enum LIDError: Error, LocalizedError, ClassifiableLIDError {
        case unavailable(String)
        case whisperFailed(Int32, String)
        case unparseable(String)
        case offWhitelist(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let m): return "WhisperLID unavailable: \(m)"
            case .whisperFailed(let c, let out): return "whisper -dl exited \(c): \(out.suffix(200))"
            case .unparseable(let s): return "could not parse detected language from: \(s.suffix(200))"
            case .offWhitelist(let lang): return "detected language '\(lang)' is not in the whitelist"
            }
        }
        /// `unavailable` means the LID can't run at all (missing binary/model)
        /// → structural: every segment will fail identically, so fail the call
        /// and let it backlog. `whisperFailed` (a non-zero exit) stays soft —
        /// pre-v2 degraded those to `unknown` rather than risk a retry loop on
        /// a transient hiccup — as do the this-clip-only verdicts.
        var isStructural: Bool {
            switch self {
            case .unavailable:                              return true
            case .whisperFailed, .unparseable, .offWhitelist: return false
            }
        }
    }

    func identify(pcm: Data,
                  sampleRateHz: Int,
                  restrict: [String]) throws -> [String: Double] {
        guard !binary.isEmpty,
              FileManager.default.isExecutableFile(atPath: binary) else {
            throw LIDError.unavailable("whisper binary missing")
        }
        guard !model.isEmpty, FileManager.default.fileExists(atPath: model) else {
            throw LIDError.unavailable("LID-driver model missing")
        }
        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostie-lid-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try AudioStitcher.writeWAV(pcm, to: scratch, sampleRate: sampleRateHz)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = ["-m", model, "-f", scratch.path, "-l", "auto", "--detect-language"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch {
            throw LIDError.whisperFailed(-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else {
            throw LIDError.whisperFailed(p.terminationStatus, out)
        }
        guard let (lang, prob) = Self.parse(out) else {
            throw LIDError.unparseable(out)
        }
        let mapped = remapTop(lang.lowercased())
        guard restrict.contains(mapped) else {
            throw LIDError.offWhitelist(mapped)
        }
        return Self.spread(top: mapped, confidence: prob, restrict: restrict)
    }

    /// Parse the `auto-detected language: <code> (p = 0.87)` line.
    /// Public to keep parity with the prior in-segmenter version that
    /// `runCodeSwitchSelfTest` could call without spinning up a process.
    static func parse(_ text: String) -> (String, Double)? {
        for line in text.split(whereSeparator: \.isNewline) {
            let l = line.lowercased()
            guard let r = l.range(of: "detected language:") else { continue }
            let rest = l[r.upperBound...].trimmingCharacters(in: .whitespaces)
            guard let lang = rest.split(whereSeparator: { $0 == " " || $0 == "(" })
                .first.map(String.init), !lang.isEmpty else { continue }
            var p = 1.0
            if let pr = l.range(of: "p = ") ?? l.range(of: "p=") {
                let tail = l[pr.upperBound...]
                let num = tail.prefix { $0.isNumber || $0 == "." }
                p = Double(num) ?? 1.0
            }
            return (lang, p)
        }
        return nil
    }

    /// Spread a top-1 + confidence across `restrict` as a log-prob map: mass
    /// `confidence` on `top` (clamped to (0.001, 0.999)), the residual
    /// uniformly across the rest. Off-whitelist `top` returns uniform.
    /// Thin wrapper over `LogProb.skewed` — the single definition of the shape.
    static func spread(top: String,
                       confidence: Double,
                       restrict: [String]) -> [String: Double] {
        LogProb.skewed(toward: top, mass: confidence, over: restrict)
    }
}

// MARK: - ServerWhisperLID — resident whisper-server language head

/// Per-segment language ID via a resident `whisper-server` process.
///
/// `WhisperLID` spawns `whisper-cli --detect-language` once per VAD segment,
/// and every spawn reloads the ~1.1 GB driver model from scratch
/// (~4.8 s/segment measured). This identifier starts `whisper-server` ONCE
/// per call (model loads at startup, ~1 s) and answers each segment with a
/// multipart POST to `/inference` (~1.2 s warm, bit-identical probabilities
/// to the CLI head — verified on whisper.cpp 1.8.4).
///
/// Lifecycle is strictly owned by Ghostie: the server has no idle-exit or
/// parent-death option, so whoever builds this identifier must call
/// `shutdown()` when the call's detect work finishes, success OR throw —
/// `CodeSwitchTranscriber.transcribeBoth` does that with a `defer`. `deinit`
/// is only a safety net; it cannot run on a hard crash (SIGKILL), which can
/// orphan one `whisper-server` until the user notices or reboots.
///
/// A class (not a struct) because it owns mutable process state; all entry
/// points serialize on `lock`, matching the pipeline's sequential use (the
/// server serializes concurrent requests internally anyway).
final class ServerWhisperLID: LanguageIdentifier {
    let serverBinary: String
    let model: String
    /// Same policy injection as `WhisperLID.remapTop`: folds Nordic
    /// look-alikes into `sv` before whitelist enforcement. Identity by default.
    let remapTop: (String) -> String

    private let lock = NSLock()
    private var process: Process?
    private var port: Int = 0

    /// Model load happens before the server binds, typically ~1 s; allow a
    /// generous ceiling for cold Metal shader caches on first run.
    private static let startupTimeout: TimeInterval = 30
    private static let requestTimeout: TimeInterval = 60

    init(serverBinary: String,
         model: String,
         remapTop: @escaping (String) -> String = { $0 }) {
        self.serverBinary = serverBinary
        self.model = model
        self.remapTop = remapTop
    }

    deinit { shutdown() }

    var description: String {
        "whisper-server language head (resident, \((model as NSString).lastPathComponent))"
    }

    /// Mirrors `WhisperLID.LIDError`'s structural/soft split so
    /// `LanguageSegmenter` backlogs the call on a can't-run-at-all failure
    /// and absorbs a this-clip-only failure into the `unknown` floor.
    enum LIDError: Error, LocalizedError, ClassifiableLIDError {
        case unavailable(String)
        case startupFailed(String)
        case serverDied(String)
        case requestFailed(String)
        case badStatus(Int, String)
        case unparseable(String)
        case offWhitelist(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let m): return "ServerWhisperLID unavailable: \(m)"
            case .startupFailed(let m): return "whisper-server failed to start: \(m.suffix(200))"
            case .serverDied(let m): return "whisper-server died and a restart did not help: \(m.suffix(200))"
            case .requestFailed(let m): return "whisper-server request failed: \(m.suffix(200))"
            case .badStatus(let c, let body): return "whisper-server returned HTTP \(c): \(body.suffix(200))"
            case .unparseable(let s): return "could not parse whisper-server LID response: \(s.suffix(200))"
            case .offWhitelist(let lang): return "detected language '\(lang)' is not in the whitelist"
            }
        }
        /// Missing binary/model and a server that won't start (or won't stay
        /// up through a restart) poison every segment identically →
        /// structural, fail the call so it backlogs and retries cleanly.
        /// A single bad request/response stays soft, like `whisperFailed`.
        var isStructural: Bool {
            switch self {
            case .unavailable, .startupFailed, .serverDied:    return true
            case .requestFailed, .badStatus, .unparseable, .offWhitelist: return false
            }
        }
    }

    func identify(pcm: Data,
                  sampleRateHz: Int,
                  restrict: [String]) throws -> [String: Double] {
        lock.lock()
        defer { lock.unlock() }
        guard !serverBinary.isEmpty,
              FileManager.default.isExecutableFile(atPath: serverBinary) else {
            throw LIDError.unavailable("whisper-server binary missing")
        }
        guard !model.isEmpty, FileManager.default.fileExists(atPath: model) else {
            throw LIDError.unavailable("LID-driver model missing")
        }
        try ensureStartedLocked()

        let scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostie-lid-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: scratch) }
        try AudioStitcher.writeWAV(pcm, to: scratch, sampleRate: sampleRateHz)
        let wav: Data
        do { wav = try Data(contentsOf: scratch) } catch {
            throw LIDError.requestFailed("could not read back temp WAV: \(error.localizedDescription)")
        }

        let (data, http) = try postLocked(wav: wav, allowRestart: true)
        guard http.statusCode == 200 else {
            // Malformed requests come back as HTTP 400 with a PLAIN TEXT body
            // ("Invalid request"), not JSON — surface it verbatim, soft.
            throw LIDError.badStatus(http.statusCode,
                                     String(data: data, encoding: .utf8) ?? "")
        }
        guard let (code, prob) = Self.parseDetection(data) else {
            throw LIDError.unparseable(String(data: data, encoding: .utf8) ?? "<binary>")
        }
        let mapped = remapTop(code.lowercased())
        guard restrict.contains(mapped) else {
            throw LIDError.offWhitelist(mapped)
        }
        // EXACT output parity with WhisperLID: collapse to top-1 + confidence
        // and spread the residual uniformly, so the Smoother sees the same
        // distribution family no matter which whisper LID answered. A richer
        // option — renormalizing the full `language_probabilities` map over
        // `restrict` — is a future refinement once the smoother is calibrated
        // against real multi-mass posteriors.
        return WhisperLID.spread(top: mapped, confidence: prob, restrict: restrict)
    }

    /// Parse whisper-server's `verbose_json` LID response into (code, prob).
    ///
    /// Gotcha (verified on whisper.cpp 1.8.4): `detected_language` is the
    /// FULL ENGLISH NAME ("english", "swedish"), never an ISO code — do not
    /// parse it as a label. The code comes from the argmax of
    /// `language_probabilities` (an ISO-code → prob map, thresholded so it
    /// sums to < 1) and the confidence from `detected_language_probability`
    /// (falling back to the argmax's own value if absent).
    ///
    /// Static + pure so `runCodeSwitchSelfTest` exercises it with canned JSON,
    /// no process or network.
    static func parseDetection(_ data: Data) -> (code: String, prob: Double)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawProbs = root["language_probabilities"] as? [String: Any] else {
            return nil
        }
        var top: (code: String, p: Double)?
        for (code, v) in rawProbs {
            guard let p = (v as? NSNumber)?.doubleValue else { continue }
            if top == nil || p > top!.p { top = (code, p) }
        }
        guard let top else { return nil }
        let prob = (root["detected_language_probability"] as? NSNumber)?.doubleValue ?? top.p
        return (top.code.lowercased(), prob)
    }

    /// `/inference` multipart payload: the WAV plus `detect_language=true`
    /// (skips decoding entirely — LID-only, ~1.2 s warm regardless of clip
    /// length ≤ 30 s) and `response_format=verbose_json` (the only format
    /// that carries `language_probabilities`). Static + pure for the selftest.
    static func multipartBody(wav: Data, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"segment.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(wav)
        body.append(Data("\r\n".utf8))
        field("detect_language", "true")
        field("response_format", "verbose_json")
        body.append(Data("--\(boundary)--\r\n".utf8))
        return body
    }

    // MARK: Lifecycle

    /// Deterministic teardown: SIGTERM (clean exit within ~500 ms, verified),
    /// brief wait, SIGKILL fallback. Idempotent — safe to call from both the
    /// owner's `defer` and `deinit`.
    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        guard let p = process else { return }
        process = nil
        guard p.isRunning else { return }
        p.terminate()                                  // SIGTERM
        let deadline = Date().addingTimeInterval(1.5)
        while p.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        p.waitUntilExit()                              // reap
    }

    /// Lazy start on first identify. Picks a free port by binding a socket to
    /// port 0 and closing it; the tiny grab-race window is covered by up to 3
    /// retries on a fresh port. Readiness = `GET /` returns 200 (the server
    /// loads the model BEFORE binding, so the first 200 means "model loaded").
    private func ensureStartedLocked() throws {
        if let p = process, p.isRunning { return }
        process = nil
        var lastError = "no free port"
        for _ in 0..<3 {
            guard let candidate = Self.freePort() else { continue }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: serverBinary)
            // NEVER pass `-nlp` here — it strips `language_probabilities`
            // from the response (verified), which is the whole point.
            p.arguments = ["-m", model,
                           "--host", "127.0.0.1", "--port", "\(candidate)"]
            // Discard server logs; an unread Pipe would fill up and stall the
            // server on a long call.
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch {
                lastError = error.localizedDescription
                continue
            }
            if Self.waitUntilReady(port: candidate, process: p) {
                process = p
                port = candidate
                Log.info("whisper-server up on 127.0.0.1:\(candidate) "
                    + "(\((model as NSString).lastPathComponent))")
                return
            }
            if p.isRunning { p.terminate() }
            p.waitUntilExit()
            lastError = "server did not become ready on port \(candidate)"
        }
        throw LIDError.startupFailed(lastError)
    }

    private static func waitUntilReady(port: Int, process p: Process) -> Bool {
        let deadline = Date().addingTimeInterval(startupTimeout)
        guard let url = URL(string: "http://127.0.0.1:\(port)/") else { return false }
        while Date() < deadline {
            // The server exits straight away on a bad bind / bad model —
            // don't keep polling a corpse for 30 s.
            if !p.isRunning { return false }
            var req = URLRequest(url: url)
            req.httpMethod = "GET"
            req.timeoutInterval = 2
            if case .success((_, let http)) = syncDataTask(request: req, timeout: 2),
               http.statusCode == 200 {
                return true
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        return false
    }

    /// Bind an ephemeral socket to port 0, read back the kernel-assigned
    /// port, close. Classic find-a-free-port; raceable, hence the retries.
    private static func freePort() -> Int? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { return nil }
        var assigned = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        guard named == 0 else { return nil }
        return Int(UInt16(bigEndian: assigned.sin_port))
    }

    // MARK: HTTP

    /// POST one segment. Connection-refused after a successful startup means
    /// the server died underneath us → ONE restart + retry; if the restart
    /// fails (`startupFailed`) or the retried request still can't connect
    /// (`serverDied`), the error is structural so the segmenter rethrows and
    /// the call backlogs + retries cleanly. Other failures (timeouts, …)
    /// stay soft.
    private func postLocked(wav: Data, allowRestart: Bool) throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/inference")!)
        req.httpMethod = "POST"
        let boundary = "ghostie-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.multipartBody(wav: wav, boundary: boundary)
        req.timeoutInterval = Self.requestTimeout

        switch Self.syncDataTask(request: req, timeout: Self.requestTimeout) {
        case .success(let pair):
            return pair
        case .failure(let err):
            guard Self.isConnectionFailure(err) else {
                throw LIDError.requestFailed(err.localizedDescription)
            }
            guard allowRestart else {
                throw LIDError.serverDied(err.localizedDescription)
            }
            Log.warn("whisper-server connection lost — restarting once…")
            stopLocked()
            try ensureStartedLocked()
            return try postLocked(wav: wav, allowRestart: false)
        }
    }

    private static func isConnectionFailure(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain
            && (ns.code == NSURLErrorCannotConnectToHost
                || ns.code == NSURLErrorNetworkConnectionLost)
    }

    /// `URLSession.dataTask` behind a semaphore so call sites stay
    /// synchronous — same house style as `OllamaSummarizationProvider`.
    /// The pipeline runs on a work queue, never the main thread.
    private static func syncDataTask(
        request: URLRequest,
        timeout: TimeInterval
    ) -> Result<(Data, HTTPURLResponse), Error> {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)
        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error> =
            .failure(NSError(domain: "ghostie", code: 99,
                             userInfo: [NSLocalizedDescriptionKey: "no response"]))
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                result = .success((data ?? Data(), http))
            } else {
                result = .failure(NSError(domain: "ghostie", code: 98, userInfo: [
                    NSLocalizedDescriptionKey: "Unexpected response from whisper-server."
                ]))
            }
            sem.signal()
        }
        task.resume()
        // Wait a bit beyond the per-request timeout so URLSession fires its
        // own timeout error instead of us racing it.
        _ = sem.wait(timeout: .now() + timeout + 5)
        session.finishTasksAndInvalidate()
        return result
    }
}

// MARK: - VoxLingua107LID — stub for the v2 ONNX integration

/// Placeholder for the v2 dedicated short-segment LID
/// (VoxLingua107 ECAPA-TDNN via ONNX Runtime; see `code-switching-v2.md` §2).
/// Throws `notWired` until the ONNX integration commit lands — the segmenter
/// degrades to `WhisperLID` when this identifier isn't usable, so installing
/// the ONNX framework and the model is the only step needed to flip the
/// real LID on.
///
/// Why a stub now: PRs 4–5 (snap-to-silence, post-decode re-verification)
/// only need the *abstraction*, not a working ONNX session. Landing the
/// protocol seam early means those PRs can be reviewed and tested without
/// blocking on framework / model download work that needs the user's
/// hardware in front of them.
struct VoxLingua107LID: LanguageIdentifier {
    let modelPath: String

    var description: String {
        let name = (modelPath as NSString).lastPathComponent
        return "VoxLingua107 ECAPA-TDNN (ONNX, \(name.isEmpty ? "not installed" : name))"
    }

    enum LIDError: Error, LocalizedError {
        case notWired
        var errorDescription: String? {
            "VoxLingua107 LID is not yet wired (no ONNX Runtime in this build). Falling back to WhisperLID."
        }
    }

    func identify(pcm: Data,
                  sampleRateHz: Int,
                  restrict: [String]) throws -> [String: Double] {
        throw LIDError.notWired
    }

    /// True once the ONNX framework is linked AND the model file is on disk.
    /// `LanguageSegmenter` consults this to decide whether to use this
    /// identifier or fall back to `WhisperLID`. Today it's always false
    /// because no ONNX Runtime is linked; future commit flips it on.
    var isReady: Bool { false }
}
