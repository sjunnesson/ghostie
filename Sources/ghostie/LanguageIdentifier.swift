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
