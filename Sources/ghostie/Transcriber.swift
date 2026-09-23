import Foundation

/// Wraps the whisper.cpp CLI to transcribe a WAV file locally. The audio never
/// leaves the machine — this is the privacy-critical step for call recordings.
struct Transcriber {

    struct Segment {
        let startMs: Int
        let text: String
        /// Whisper's own segment end, when the JSON carried one. Diarization
        /// needs a span to embed, and inferring it from the next segment's
        /// start would swallow the pause in between — which is exactly where
        /// a speaker change lives, and the last place you want to sample
        /// someone's voice from.
        var endMs: Int? = nil
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
        // Hallucination-resistant decoding. whisper-cli's defaults already
        // match the production-tuned values (best-of 5, entropy 2.4, logprob
        // -1.0, no-speech 0.6); we set them explicitly so a future default
        // change can't silently regress quality, and add the two flags that
        // are OFF by default but matter most: non-speech-token suppression and
        // (when a model is available) Voice Activity Detection.
        var args = [
            "-m", config.whisperModel,
            "-f", wav.path,
            "-l", config.language,
            "-bo", "5", "-bs", "5",
            "-et", "2.40", "-lpt", "-1.00", "-nth", "0.60",
            "-sns",                // suppress non-speech tokens ([music] etc.)
            "-oj",                 // write <prefix>.json
            "-of", prefix,
            "-np"                  // no progress prints
            // NOTE: never pass -nt here — verified empirically (whisper-cpp
            // 1.8.4): with --vad it collapses the <prefix>.json transcription
            // to a single whole-file segment at offset 0, which breaks the
            // cross-track timestamp merge. Stdout text is unused, so dropping
            // it loses nothing.
        ]
        if !config.initialPrompt.isEmpty {
            args += ["--prompt", config.initialPrompt]
        }
        if !config.vadModel.isEmpty,
           FileManager.default.fileExists(atPath: config.vadModel) {
            args += ["--vad", "--vad-model", config.vadModel]
        }
        proc.arguments = args

        Log.info("Transcribing \(speaker) track…")
        // `runWatched` drains the pipe while waiting (whisper-cli prints the
        // transcript to stdout and would block on a full pipe) and kills a
        // decode that has hung.
        let (status, out) = try runWatched(proc, timeout: Self.timeout(for: wav))
        guard status == 0 else {
            throw NSError(domain: "ghostie", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "whisper exited \(status): \(out)"
            ])
        }

        let jsonURL = URL(fileURLWithPath: prefix + ".json")
        return try Self.parse(jsonURL)
    }

    /// Budget for one whisper-cli pass over `wav`: four times its length, and
    /// never under 15 minutes. Measured decode speed is ~0.18× real time
    /// (10.6 s per audio minute on large-v3), so this only trips on a decode
    /// that has stopped making progress — which then throws, and the call
    /// goes to the backlog instead of wedging the pipeline queue.
    static func timeout(for wav: URL) -> TimeInterval {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: wav.path))?[.size] as? Int ?? 0
        let seconds = Double(max(0, bytes - 44)) / 32_000   // 16 kHz mono Int16
        return max(15 * 60, 4 * seconds)
    }

    /// Parses whisper.cpp's JSON output. Schema:
    /// { "transcription": [ { "offsets": { "from": <ms>, ... }, "text": "..." } ] }
    ///
    /// Throws when the file is missing or is not that shape. whisper-cli
    /// ignores its JSON writer's result, so a full disk exits 0 with a
    /// truncated file or none; reading that as "no speech" wrote a "No speech
    /// detected" note and deleted the recording. Silence is a *present*
    /// `"transcription": []` (checked against whisper-cli 1.8 with and
    /// without `--vad`), and still parses to no segments.
    static func parse(_ url: URL) throws -> [Segment] {
        let items = try transcriptionItems(url)
        var segments: [Segment] = []
        for item in items {
            let text = (item["text"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { continue }
            let offsets = item["offsets"] as? [String: Any]
            let from = (offsets?["from"] as? Int)
                ?? (offsets?["from"] as? NSNumber)?.intValue ?? 0
            let to = (offsets?["to"] as? Int)
                ?? (offsets?["to"] as? NSNumber)?.intValue
            segments.append(Segment(startMs: from, text: text,
                                    endMs: to.map { max($0, from) }))
        }
        return segments
    }

    /// The `transcription` array of a whisper-cli `-oj` file. Throws when the
    /// file is absent or unreadable as that shape — see `parse`.
    static func transcriptionItems(_ url: URL) throws -> [[String: Any]] {
        guard let data = try? Data(contentsOf: url) else {
            throw NSError(domain: "ghostie", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "whisper wrote no output at \(url.lastPathComponent)"])
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["transcription"] as? [[String: Any]] else {
            throw NSError(domain: "ghostie", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "whisper output \(url.lastPathComponent) is truncated or malformed"])
        }
        return items
    }
}
