import Foundation

/// What `ghostie transcribe-probe` collects from one run of the code-switch
/// transcriber. A class so the (value-type) transcriber can write into it.
final class CodeSwitchTrace {
    var identifier = ""
    var seconds: [String: Double] = [:]
    var detections: [String: [LanguageDetection]] = [:]
    var runs: [String: [LanguageRun]] = [:]
    /// Stop once the language runs are known — the routing experiments need
    /// the timeline, not a decode.
    var stopAfterRouting = false
}

extension Optional where Wrapped == CodeSwitchTrace {
    /// Run `body`, adding its wall time to `stage` when a trace is attached.
    func timed<T>(_ stage: String, _ body: () throws -> T) rethrows -> T {
        guard let trace = self else { return try body() }
        let t0 = Date()
        defer { trace.seconds[stage, default: 0] += Date().timeIntervalSince(t0) }
        return try body()
    }
}

/// Hidden: run the transcription stage alone over a kept session and write
/// what it decided — detections, language runs, segments, per-stage seconds —
/// as JSON, so a routing or decoder change is one command to measure.
///
///     ghostie transcribe-probe <session-dir> --out <dir>
///         [--routing-only] [--set codeSwitch.<key>=<json>]…
///
/// Nothing is cleaned, merged, summarized or written to the notes folder, and
/// the session's WAVs are only read.
func cmdTranscribeProbe(_ base: Config, args: [String]) {
    // An experiment is not a call: keep its lines out of ghostie.log, which
    // is read as the record of what happened to real recordings.
    Log.writesToFile = false
    var config = base
    var session: String?
    var outDir: String?
    var routingOnly = false
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--out": i += 1; outDir = i < args.count ? args[i] : nil
        case "--routing-only": routingOnly = true
        case "--set":
            i += 1
            guard i < args.count, let eq = args[i].firstIndex(of: "=") else {
                Log.error("--set takes codeSwitch.<key>=<json value>"); exit(1)
            }
            let key = String(args[i][..<eq]), value = String(args[i][args[i].index(after: eq)...])
            guard key.hasPrefix("codeSwitch."),
                  let patched = TranscribeProbe.patch(config.codeSwitch,
                                                      key: String(key.dropFirst("codeSwitch.".count)),
                                                      json: value) else {
                Log.error("could not set \(key) to \(value)"); exit(1)
            }
            config.codeSwitch = patched
        default: session = a
        }
        i += 1
    }
    guard let session, let outDir else {
        Log.error("Usage: ghostie transcribe-probe <session-dir> --out <dir> [--routing-only] [--set codeSwitch.<key>=<json>]…")
        exit(1)
    }
    let dir = URL(fileURLWithPath: session)
    let out = URL(fileURLWithPath: outDir)
    try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

    let installed = Models.installed(preferredKBVariant: config.codeSwitch.kbWhisperVariant)
    var cst = CodeSwitchTranscriber(config: config, installed: installed)
    let trace = CodeSwitchTrace()
    trace.stopAfterRouting = routingOnly
    cst.trace = trace

    let t0 = Date()
    do {
        let (me, part) = try cst.transcribeBoth(
            me: dir.appendingPathComponent("me.wav"),
            participants: dir.appendingPathComponent("participants.wav"))
        let total = Date().timeIntervalSince(t0)
        for (tag, segs) in [("me", me), ("participants", part)] {
            if !routingOnly {
                TranscribeProbe.write(["transcription": segs.map { s -> [String: Any] in
                    ["offsets": ["from": s.startMs, "to": s.endMs ?? s.startMs], "text": s.text]
                }], to: out.appendingPathComponent("\(tag).segments.json"))
            }
            TranscribeProbe.write((trace.runs[tag] ?? []).map { r -> [String: Any] in
                ["language": r.language, "startMs": r.startMs, "endMs": r.endMs]
            }, to: out.appendingPathComponent("\(tag).runs.json"))
            TranscribeProbe.write((trace.detections[tag] ?? []).map { d -> [String: Any] in
                ["startMs": d.segment.startMs, "endMs": d.segment.endMs, "top": d.top,
                 "margin": d.margin.isFinite ? d.margin : 0,
                 "logprobs": d.logprobs.filter { $0.value.isFinite }]
            }, to: out.appendingPathComponent("\(tag).detections.json"))
        }
        var timings: [String: Any] = ["total": total, "identifier": trace.identifier]
        for (k, v) in trace.seconds { timings[k] = v }
        TranscribeProbe.write(timings, to: out.appendingPathComponent("timings.json"))
        let stages = trace.seconds.sorted { $0.key < $1.key }
            .map { String(format: "%@ %.0f s", $0.key, $0.value) }.joined(separator: ", ")
        print(String(format: "transcribe-probe: %.0f s total (%@) — %@", total, stages, trace.identifier))
        for tag in ["me", "participants"] {
            let runs = trace.runs[tag] ?? []
            let byLang = Dictionary(grouping: runs, by: \.language)
                .mapValues { $0.reduce(0) { $0 + ($1.endMs - $1.startMs) } / 1000 }
            print("  \(tag): \(runs.count) runs, "
                + byLang.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value) s" }.joined(separator: ", "))
        }
    } catch {
        Log.error("transcribe-probe failed: \(error.localizedDescription)")
        exit(1)
    }
}

enum TranscribeProbe {
    /// `config` with one top-level key replaced by a JSON value, through the
    /// config's own decoder so a mistyped key or type fails here rather than
    /// being silently ignored.
    static func patch(_ config: CodeSwitchConfig, key: String, json: String) -> CodeSwitchConfig? {
        guard let data = try? JSONEncoder().encode(config),
              var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              dict[key] != nil,
              let value = try? JSONSerialization.jsonObject(
                  with: Data(json.utf8), options: [.fragmentsAllowed]) else { return nil }
        dict[key] = value
        guard let patched = try? JSONSerialization.data(withJSONObject: dict) else { return nil }
        return try? JSONDecoder().decode(CodeSwitchConfig.self, from: patched)
    }

    static func write(_ object: Any, to url: URL) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
