import Foundation

/// Turns a finished recording into a markdown note:
/// transcribe both tracks → merge by timestamp with speaker labels →
/// summarize → write `<notesFolder>/<date>_Teams-Call.md` (+ transcript).
struct Pipeline {
    let config: Config

    private struct Line {
        let startMs: Int
        let speaker: String
        let text: String
    }

    @discardableResult
    func process(_ rec: AudioRecorder.Result, startedAt: Date) -> URL? {
        let mins = String(format: "%.1f", rec.duration / 60.0)
        Log.info("Processing recording (\(mins) min) at \(rec.sessionDir.lastPathComponent)…")

        let transcriber = Transcriber(config: config)
        var lines: [Line] = []
        var transcriptError: String?

        // Clean each track independently before merging — hallucination
        // loops are per-track, so guarding pre-merge is more accurate.
        func collect(_ wav: URL, _ speaker: String) throws {
            let raw = try transcriber.transcribe(wav, speaker: speaker)
            let segments: [(startMs: Int, text: String)]
            if config.cleanTranscript {
                let (cleaned, stats) = TranscriptCleaner.clean(
                    raw.map { (startMs: $0.startMs, text: $0.text) })
                if stats.removed > 0 { Log.info("\(speaker): \(stats.summary)") }
                segments = cleaned.map { (startMs: $0.startMs, text: $0.text) }
            } else {
                segments = raw.map { (startMs: $0.startMs, text: $0.text) }
            }
            for s in segments {
                lines.append(Line(startMs: s.startMs, speaker: speaker, text: s.text))
            }
        }

        do {
            try collect(rec.micWav, "Me")
            try collect(rec.systemWav, "Participants")
        } catch {
            transcriptError = error.localizedDescription
            Log.error("Transcription failed: \(error.localizedDescription)")
        }

        lines.sort { $0.startMs < $1.startMs }
        let transcript = lines.isEmpty
            ? "_(No speech was transcribed.)_"
            : lines.map { "**[\(Self.clock($0.startMs))] \($0.speaker):** \($0.text)" }
                   .joined(separator: "\n\n")

        let started = Self.human.string(from: startedAt)
        let meta = """
        - Date: \(started)
        - Duration: \(mins) minutes
        - Captured locally via ScreenCaptureKit (no bot joined the call)
        """

        // Summarize (best-effort — never lose the transcript if this fails).
        var summary: String
        let summarizer = Summarizer(config: config)
        if let transcriptError {
            summary = "> ⚠️ Transcription unavailable: \(transcriptError)\n>\n> Run `scripts/setup.sh` to install whisper.cpp and a model."
        } else if lines.isEmpty {
            summary = "_No speech detected on either track, so there is nothing to summarize._"
        } else if summarizer.isConfigured {
            do {
                summary = try summarizer.summarize(transcript: transcript, meta: meta)
                Log.ok("Summary generated.")
            } catch {
                summary = "> ⚠️ Summary generation failed: \(error.localizedDescription)\n>\n> The full transcript below is still complete."
                Log.error("Summarization failed: \(error.localizedDescription)")
            }
        } else {
            summary = "> ℹ️ No Anthropic API key configured, so no AI analysis was produced.\n> Set `ANTHROPIC_API_KEY` (or add it to `~/.ghostie/config.json`) to enable the Context / Decisions / Action Items analysis.\n>\n> The full transcript is below."
        }

        let noteURL = writeNote(meta: meta, summary: summary,
                                transcript: transcript, startedAt: startedAt)

        if !config.keepAudio {
            try? FileManager.default.removeItem(at: rec.sessionDir)
        } else {
            Log.info("Audio kept at \(rec.sessionDir.path)")
        }
        return noteURL
    }

    private func writeNote(meta: String, summary: String,
                           transcript: String, startedAt: Date) -> URL? {
        let folder = URL(fileURLWithPath: config.notesFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let base = Self.fileStamp.string(from: startedAt) + "_Teams-Call"
        let noteURL = folder.appendingPathComponent(base + ".md")

        var doc = """
        # Teams Call — \(Self.human.string(from: startedAt))

        \(meta)

        ---

        \(summary)
        """

        if config.saveTranscript {
            let transcriptURL = folder.appendingPathComponent(base + "_transcript.md")
            let tdoc = "# Transcript — \(Self.human.string(from: startedAt))\n\n\(meta)\n\n---\n\n\(transcript)\n"
            try? tdoc.write(to: transcriptURL, atomically: true, encoding: .utf8)
            doc += "\n\n---\n\n## Full Transcript\n\n[Separate file](\(transcriptURL.lastPathComponent))\n\n<details><summary>Inline transcript</summary>\n\n\(transcript)\n\n</details>\n"
        } else {
            doc += "\n\n---\n\n## Full Transcript\n\n\(transcript)\n"
        }

        do {
            try doc.write(to: noteURL, atomically: true, encoding: .utf8)
            Log.ok("Note saved → \(noteURL.path)")
            return noteURL
        } catch {
            Log.error("Failed to write note: \(error.localizedDescription)")
            return nil
        }
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static let human: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMM yyyy 'at' HH:mm"
        return f
    }()

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm"
        return f
    }()
}
