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

    /// True for identifiers cheap enough (≲ tens of ms per window) that the
    /// segmenter may run the fine sliding-window pass, which multiplies
    /// `identify` calls by the window count. Whisper-based LIDs (~1.2 s per
    /// window even warm) return the default false and skip the fine pass.
    var isLowLatency: Bool { get }
}

extension LanguageIdentifier {
    /// Default no-op so existing identifiers and test stubs conform unchanged.
    func shutdown() {}
    /// Conservative default: only identifiers that opt in get the fine pass.
    var isLowLatency: Bool { false }
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
    ///
    /// `confidence` is whisper's mass over its full ~100-language softmax.
    /// Re-spread verbatim over a small whitelist, a weak top-1 (p < 1/N)
    /// would put more mass on every *other* whitelist language than on the
    /// model's own best guess — inverting the evidence, so `detect` labels
    /// the segment with a language the LID did NOT pick. Conditional on the
    /// whitelist the top's true share is ≥ 1/N by construction, so clamp the
    /// mass to a strict edge above uniform: weak detections stay weak (the
    /// smoother's prior can still overrule them) but never flip sign.
    static func spread(top: String,
                       confidence: Double,
                       restrict: [String]) -> [String: Double] {
        let uniform = 1.0 / Double(max(1, restrict.count))
        return LogProb.skewed(toward: top,
                              mass: max(confidence, uniform + 0.05),
                              over: restrict)
    }
}

// MARK: - ServerWhisperLID — resident whisper-server language head

/// Per-segment language ID via a resident `whisper-server` process.
///
/// `WhisperLID` spawns `whisper-cli --detect-language` once per VAD segment,
/// and every spawn reloads the ~1.1 GB driver model from scratch
/// (~4.8 s/segment measured). This identifier starts `whisper-server` ONCE
/// per call (model loads at startup, ~1 s) and answers each segment with a
/// multipart POST to `/inference` (~1.2 s warm, bit-identical head
/// probabilities to the CLI — verified on whisper.cpp 1.8.4).
///
/// Unlike the CLI head (which prints only a top-1 + confidence), the server
/// returns the full `language_probabilities` map, and this identifier uses
/// it: look-alike mass is folded through `remap` BEFORE the argmax, and the
/// whitelist languages' real competing masses are renormalized into the
/// posterior (see `restrictedPosterior`) instead of being replaced by
/// `WhisperLID.spread`'s fabricated uniform residual.
///
/// Lifecycle is strictly owned by Ghostie: whoever builds this identifier
/// must call `shutdown()` when the call's detect work finishes, success OR
/// throw — `CodeSwitchTranscriber.transcribeBoth` does that with a `defer`.
/// `deinit` is only a safety net. The server itself is spawned under a tiny
/// sh watchdog (see `ensureStartedLocked`) that kills it if ghostie dies by
/// any means — including SIGKILL, which skips every in-process cleanup — so
/// a hard crash can no longer orphan a whisper-server until reboot.
///
/// A class (not a struct) because it owns mutable process state; all entry
/// points serialize on `lock`, matching the pipeline's sequential use (the
/// server serializes concurrent requests internally anyway).
final class ServerWhisperLID: LanguageIdentifier {
    let serverBinary: String
    let model: String
    /// Same policy injection as `WhisperLID.remapTop`, but applied to EVERY
    /// language in the server's probability map (not just the top-1): each
    /// key is remapped and colliding masses are summed, so Nordic look-alike
    /// mass (`no`/`nb`/`nn`/`da`) folds INTO `sv` before the argmax instead
    /// of merely relabeling the winner. Identity by default.
    let remap: (String) -> String

    private let lock = NSLock()
    private var process: Process?
    private var port: Int = 0

    /// Model load happens before the server binds, typically ~1 s; allow a
    /// generous ceiling for cold Metal shader caches on first run.
    private static let startupTimeout: TimeInterval = 30
    private static let requestTimeout: TimeInterval = 60

    init(serverBinary: String,
         model: String,
         remap: @escaping (String) -> String = { $0 }) {
        self.serverBinary = serverBinary
        self.model = model
        self.remap = remap
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
        guard let raw = Self.parseProbabilities(data),
              let (top, logprobs) = Self.restrictedPosterior(raw, remap: remap,
                                                             restrict: restrict) else {
            throw LIDError.unparseable(String(data: data, encoding: .utf8) ?? "<binary>")
        }
        guard restrict.contains(top) else {
            throw LIDError.offWhitelist(top)
        }
        return logprobs
    }

    /// Parse whisper-server's `verbose_json` LID response into the full
    /// per-language probability map (lowercased ISO code → prob).
    ///
    /// Gotcha (verified on whisper.cpp 1.8.4): `detected_language` is the
    /// FULL ENGLISH NAME ("english", "swedish"), never an ISO code — do not
    /// parse it as a label. Everything needed lives in
    /// `language_probabilities` (thresholded, so it sums to < 1); the
    /// separate `detected_language_probability` field is redundant with the
    /// map's argmax and deliberately ignored.
    ///
    /// Static + pure so `runCodeSwitchSelfTest` exercises it with canned JSON,
    /// no process or network.
    static func parseProbabilities(_ data: Data) -> [String: Double]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawProbs = root["language_probabilities"] as? [String: Any] else {
            return nil
        }
        var out: [String: Double] = [:]
        for (code, v) in rawProbs {
            guard let p = (v as? NSNumber)?.doubleValue else { continue }
            out[code.lowercased(), default: 0] += p
        }
        return out.isEmpty ? nil : out
    }

    /// Fold `raw` through `remap` (summing colliding masses), take the global
    /// argmax, and renormalize the whitelist languages' mass into a proper
    /// log-prob posterior over `restrict` — the full-distribution upgrade
    /// over `WhisperLID.spread`'s top-1 + uniform-residual shape. The smoother
    /// gets the head's real competing evidence (sv 0.62 vs en 0.38), which is
    /// what lets a cross-track prior flip a genuinely ambiguous segment
    /// without overruling a confident one. Folding before the argmax also
    /// catches what a top-1 remap never could: `en 0.40 / no 0.32 / da 0.10`
    /// on short Swedish audio has top-1 "en", but the folded sv mass wins.
    ///
    /// `top` may be off-whitelist (e.g. German audio on an sv/en install);
    /// the caller throws `offWhitelist` so the segment falls to the
    /// segmenter's `unknown` floor rather than being force-labeled from
    /// near-zero whitelist mass. Whitelist languages absent from the
    /// (thresholded) map get a `1e-3` floor so the posterior always carries
    /// every whitelist key — `Smoother.likelihood` requires the full set —
    /// while still reading as "~1000× less likely".
    static func restrictedPosterior(_ raw: [String: Double],
                                    remap: (String) -> String,
                                    restrict: [String])
        -> (top: String, logprobs: [String: Double])? {
        var folded: [String: Double] = [:]
        for (code, p) in raw { folded[remap(code.lowercased()), default: 0] += p }
        guard let top = folded.max(by: { $0.value < $1.value })?.key else { return nil }
        var mass: [String: Double] = [:]
        for l in restrict { mass[l] = max(folded[l] ?? 0, 1e-3) }
        let sum = mass.values.reduce(0, +)
        return (top, mass.mapValues { Foundation.log($0 / sum) })
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

    /// Deterministic teardown: SIGTERM to the sh watchdog (its trap kills the
    /// server; the shell may finish a 1 s liveness sleep first), wait, SIGKILL
    /// fallback. Idempotent — safe to call from both the owner's `defer` and
    /// `deinit`.
    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        stopLocked()
    }

    private func stopLocked() {
        guard let p = process else { return }
        process = nil
        guard p.isRunning else { return }
        p.terminate()                                  // SIGTERM → trap kills server
        let deadline = Date().addingTimeInterval(3)
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
            // The server is spawned through a tiny sh watchdog so a hard
            // ghostie crash (SIGKILL — the one path that skips the owner's
            // `defer { shutdown() }`) can no longer orphan a resident
            // whisper-server until reboot: the wrapper polls its original
            // parent PID ($PPID is captured at shell start) once a second
            // and kills the server when ghostie is gone. It also exits when
            // the server itself dies, and its TERM/EXIT trap makes a normal
            // `terminate()` from stopLocked() take the server down with it.
            // NEVER pass `-nlp` to the server — it strips
            // `language_probabilities` from the response (verified), which
            // is the whole point. Paths travel via the environment, not the
            // script, so spaces never need quoting.
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", """
                "$GHOSTIE_LID_BIN" -m "$GHOSTIE_LID_MODEL" --host 127.0.0.1 --port "$GHOSTIE_LID_PORT" &
                W=$!
                trap 'kill $W 2>/dev/null' TERM INT EXIT
                while kill -0 $PPID 2>/dev/null && kill -0 $W 2>/dev/null; do sleep 1; done
                kill $W 2>/dev/null
                wait $W 2>/dev/null
                """]
            p.environment = ProcessInfo.processInfo.environment.merging([
                "GHOSTIE_LID_BIN": serverBinary,
                "GHOSTIE_LID_MODEL": model,
                "GHOSTIE_LID_PORT": "\(candidate)",
            ]) { _, new in new }
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

// MARK: - VoxLingua107LID — dedicated short-segment LID via ONNX Runtime

/// The v2 dedicated short-segment LID: VoxLingua107 ECAPA-TDNN running under
/// ONNX Runtime (see `code-switching-v2.md` §2). Activates when BOTH are on
/// disk — an onnxruntime dylib (Homebrew, `Ghostie.app/Frameworks`, or
/// `GHOSTIE_ORT_DYLIB`) and the exported model + labels produced by
/// `scripts/export-voxlingua-lid.py` — otherwise `isReady` is false and the
/// segmenter keeps the whisper LID, so behaviour never regresses.
///
/// The export wraps SpeechBrain's feature extraction INSIDE the graph, so
/// input is raw waveform: `[1, N] Float32` at 16 kHz → `[1, 107]` logits.
/// The labels sidecar (`<model>.labels.json`, written by the export script)
/// maps output indices to ISO codes in the model's own order.
final class VoxLingua107LID: LanguageIdentifier {
    let modelPath: String
    /// Same look-alike policy injection as `WhisperLID.remapTop`, applied to
    /// every posterior key before the whitelist restriction (Nordic
    /// look-alike mass folds into sv when sv is decodable and the look-alike
    /// isn't).
    let remap: (String) -> String

    private let labels: [String]
    private var session: ORTSession?
    private let lock = NSLock()

    init(modelPath: String, remap: @escaping (String) -> String = { $0 }) {
        self.modelPath = modelPath
        self.remap = remap
        self.labels = Self.loadLabels(modelPath: modelPath)
    }

    var description: String {
        let name = (modelPath as NSString).lastPathComponent
        if isReady {
            return "VoxLingua107 ECAPA-TDNN (ONNX, \(name), \(labels.count) languages)"
        }
        let missing = !FileManager.default.fileExists(atPath: modelPath)
            ? "model not installed — run scripts/export-voxlingua-lid.py"
            : (ORTRuntime.shared == nil
                ? "onnxruntime dylib not found — brew install onnxruntime"
                : "labels sidecar missing")
        return "VoxLingua107 ECAPA-TDNN (ONNX, \(missing))"
    }

    enum LIDError: Error, LocalizedError, ClassifiableLIDError {
        case notReady
        case inference(String)
        var errorDescription: String? {
            switch self {
            case .notReady: return "VoxLingua107 LID is not installed on this machine."
            case .inference(let m): return "VoxLingua107 LID inference failed: \(m)"
            }
        }
        /// Missing runtime/model is structural (every segment fails the same
        /// way → backlog and retry); a single inference failure is soft.
        var isStructural: Bool {
            if case .notReady = self { return true }
            return false
        }
    }

    /// Sidecar written by the export script: a JSON array of ISO codes in
    /// output-index order.
    static func loadLabels(modelPath: String) -> [String] {
        let path = modelPath + ".labels.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let labels = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return labels.map { $0.lowercased() }
    }

    /// ~10 ms per window on Apple Silicon (measured via lid-probe) — cheap
    /// enough for the sliding-window fine pass.
    var isLowLatency: Bool { true }

    /// Ready when the runtime loads, the model file exists, and the labels
    /// sidecar parsed. `LanguageSegmenter.defaultIdentifier` consults this
    /// to pick between the ONNX LID and the whisper fallback.
    var isReady: Bool {
        ORTRuntime.shared != nil
            && !labels.isEmpty
            && FileManager.default.fileExists(atPath: modelPath)
    }

    func identify(pcm: Data,
                  sampleRateHz: Int,
                  restrict: [String]) throws -> [String: Double] {
        guard isReady, let runtime = ORTRuntime.shared else { throw LIDError.notReady }
        let session: ORTSession
        do {
            session = try ensureSession(runtime: runtime)
        } catch {
            // A model that cannot load will not load for any segment.
            throw LIDError.notReady
        }

        // Int16-LE PCM → normalized Float32 waveform.
        var wav = [Float](repeating: 0, count: pcm.count / 2)
        pcm.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
            let samples = buf.bindMemory(to: Int16.self)
            for i in 0..<wav.count { wav[i] = Float(Int16(littleEndian: samples[i])) / 32_768 }
        }
        guard !wav.isEmpty else { throw LIDError.inference("empty segment") }

        let logits: [Float]
        do {
            logits = try session.run(wav: wav)
        } catch {
            throw LIDError.inference(error.localizedDescription)
        }
        guard logits.count == labels.count else {
            throw LIDError.inference("model emitted \(logits.count) logits for \(labels.count) labels — model/labels mismatch")
        }

        // Softmax in log-space over all 107, fold look-alike mass through
        // `remap` BEFORE the argmax (same policy as ServerWhisperLID), then
        // renormalize the whitelist languages' real competing masses.
        let maxLogit = Double(logits.max() ?? 0)
        var linear: [String: Double] = [:]
        var total = 0.0
        for (i, l) in logits.enumerated() {
            let p = Foundation.exp(Double(l) - maxLogit)
            linear[labels[i], default: 0] += p
            total += p
        }
        guard total > 0,
              let posterior = ServerWhisperLID.restrictedPosterior(
                  linear.mapValues { $0 / total }, remap: remap, restrict: restrict)
        else { throw LIDError.inference("degenerate posterior") }
        return posterior.logprobs
    }

    private func ensureSession(runtime: ORTRuntime) throws -> ORTSession {
        lock.lock()
        defer { lock.unlock() }
        if let session { return session }
        let s = try runtime.makeSession(modelPath: modelPath)
        session = s
        Log.info("VoxLingua107 LID up (\((modelPath as NSString).lastPathComponent) via \((runtime.dylibPath as NSString).lastPathComponent))")
        return s
    }

    /// Release the ORT session at end of the call's detect work (same
    /// contract as ServerWhisperLID's server teardown).
    func shutdown() {
        lock.lock()
        defer { lock.unlock() }
        session?.close()
        session = nil
    }
}
