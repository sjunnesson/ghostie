import Foundation

/// Wraps the whisper.cpp CLI to transcribe a WAV file locally. The audio never
/// leaves the machine — this is the privacy-critical step for call recordings.
struct Transcriber {

    struct Segment {
        let startMs: Int
        let text: String
    }

    let config: Config

    var isAvailable: Bool {
        !config.whisperBinary.isEmpty
            && FileManager.default.isExecutableFile(atPath: config.whisperBinary)
            && FileManager.default.fileExists(atPath: config.whisperModel)
    }

    /// Transcribes `wav` and returns timestamped segments. `speaker` is only
    /// used for log messages here; labelling happens when transcripts merge.
    func transcribe(_ wav: URL, speaker: String) throws -> [Segment] {
        guard isAvailable else {
            throw NSError(domain: "ghostie", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "whisper.cpp not set up (binary='\(config.whisperBinary)', model='\(config.whisperModel)'). Run scripts/setup.sh."
            ])
        }

        // Skip empty/near-empty tracks (e.g. mic muted the whole call).
        if let attrs = try? FileManager.default.attributesOfItem(atPath: wav.path),
           let size = attrs[.size] as? Int, size < 16_000 {
            Log.info("\(speaker) track is essentially silent — skipping.")
            return []
        }

        let prefix = wav.deletingPathExtension().path
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.whisperBinary)
        proc.arguments = [
            "-m", config.whisperModel,
            "-f", wav.path,
            "-l", config.language,
            "-oj",                 // write <prefix>.json
            "-of", prefix,
            "-np",                 // no progress prints
            "-nt"                  // no inline timestamps in text
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        Log.info("Transcribing \(speaker) track…")
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(),
                             encoding: .utf8) ?? ""
            throw NSError(domain: "ghostie", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "whisper exited \(proc.terminationStatus): \(out)"
            ])
        }

        let jsonURL = URL(fileURLWithPath: prefix + ".json")
        return Self.parse(jsonURL)
    }

    /// Parses whisper.cpp's JSON output. Schema:
    /// { "transcription": [ { "offsets": { "from": <ms>, ... }, "text": "..." } ] }
    static func parse(_ url: URL) -> [Segment] {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["transcription"] as? [[String: Any]] else {
            return []
        }
        var segments: [Segment] = []
        for item in items {
            let text = (item["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            let offsets = item["offsets"] as? [String: Any]
            let from = (offsets?["from"] as? Int)
                ?? (offsets?["from"] as? NSNumber)?.intValue ?? 0
            segments.append(Segment(startMs: from, text: text))
        }
        return segments
    }
}
