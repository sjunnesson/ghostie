import Foundation

/// Turns a finished recording into a markdown note:
/// transcribe both tracks → merge by timestamp with speaker labels →
/// summarize → write `<notesFolder>/<date>_Teams-Call.md` (+ transcript).
///
/// If transcription or summarization can't run (whisper missing, Claude Code
/// not logged in, offline, …) the work is queued to the [Backlog] and the
/// recording is kept, so nothing is lost. `drain(config:)` retries the queue
/// whenever Ghostie can process again.
struct Pipeline {
    let config: Config
    static let maxAttempts = 6

    private struct Line {
        let startMs: Int
        let speaker: String
        let text: String
    }

    // MARK: Live processing

    @discardableResult
    func process(_ rec: AudioRecorder.Result, startedAt: Date) -> URL? {
        let durationMins = String(format: "%.1f", rec.duration / 60.0)
        Log.info("Processing recording (\(durationMins) min) at \(rec.sessionDir.lastPathComponent)…")

        let lines: [Line]
        do {
            lines = try transcribeMerge(mic: rec.micWav, sys: rec.systemWav)
        } catch {
            Log.error("Transcription failed: \(error.localizedDescription) — queued to backlog")
            Backlog.enqueueAudio(micWav: rec.micWav, systemWav: rec.systemWav,
                                 startedAt: startedAt, durationMins: durationMins)
            let url = writeNote(meta: metaBlock(startedAt, durationMins),
                summary: "> ⏳ **Queued.** Transcription wasn't available (\(error.localizedDescription)). Ghostie will process this recording automatically once it can run again.",
                transcript: "_(Pending transcription.)_", startedAt: startedAt)
            try? FileManager.default.removeItem(at: rec.sessionDir)
            return url
        }

        let transcript = render(lines)
        let meta = metaBlock(startedAt, durationMins)

        if lines.isEmpty {
            let url = writeNote(meta: meta,
                summary: "_No speech detected on either track, so there is nothing to summarize._",
                transcript: transcript, startedAt: startedAt)
            cleanup(rec.sessionDir)
            return url
        }

        let url = finishWithSummary(startedAt: startedAt, durationMins: durationMins,
                                    meta: meta, transcript: transcript)
        cleanup(rec.sessionDir)
        return url
    }

    /// Summarize and write the note; on failure queue a summary-only backlog
    /// entry and write the transcript now with a "summary queued" banner.
    @discardableResult
    private func finishWithSummary(startedAt: Date, durationMins: String,
                                   meta: String, transcript: String) -> URL? {
        let summarizer = Summarizer(config: config)
        do {
            guard summarizer.isConfigured else {
                throw NSError(domain: "ghostie", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Claude Code CLI not found / not logged in"])
            }
            let summary = try summarizer.summarize(transcript: transcript, meta: meta)
            Log.ok("Summary generated.")
            return writeNote(meta: meta, summary: summary,
                             transcript: transcript, startedAt: startedAt)
        } catch {
            Log.error("Summary unavailable: \(error.localizedDescription) — queued to backlog")
            Backlog.enqueueTranscript(startedAt: startedAt,
                                      durationMins: durationMins, transcript: transcript)
            let banner = "> ⏳ **Summary queued.** Claude Code wasn't available (\(error.localizedDescription)). Ghostie will add the analysis automatically once it can run again — the full transcript below is already complete."
            return writeNote(meta: meta, summary: banner,
                             transcript: transcript, startedAt: startedAt)
        }
    }

    // MARK: Backlog draining

    /// Try to complete every queued entry. Returns how many were finished.
    /// Safe to call repeatedly; entries that still can't run stay queued.
    @discardableResult
    static func drain(config: Config) -> Int {
        let entries = Backlog.entries()
        guard !entries.isEmpty else { return 0 }
        let p = Pipeline(config: config)
        Log.info("Backlog: \(entries.count) pending — attempting to process…")
        var completed = 0

        for entry in entries {
            let startedAt = entry.startedAtDate
            let meta = p.metaBlock(startedAt, entry.meta.durationMins)

            if entry.meta.attempts >= maxAttempts {
                p.finalizeGivenUp(entry, meta: meta)
                Backlog.remove(entry)
                completed += 1
                continue
            }

            switch entry.meta.stage {
            case "transcribe":
                guard let lines = try? p.transcribeMerge(mic: entry.micWav,
                                                         sys: entry.systemWav) else {
                    Backlog.bump(entry)            // whisper still unavailable
                    continue
                }
                let transcript = p.render(lines)
                if lines.isEmpty {
                    _ = p.writeNote(meta: meta,
                        summary: "_No speech detected on either track._",
                        transcript: transcript, startedAt: startedAt)
                    Backlog.remove(entry); completed += 1
                    continue
                }
                if let summary = p.trySummary(transcript: transcript, meta: meta) {
                    _ = p.writeNote(meta: meta, summary: summary,
                                    transcript: transcript, startedAt: startedAt)
                    Backlog.remove(entry); completed += 1
                } else {
                    // Transcribed OK but summary still down: keep the
                    // transcript so we never re-transcribe this one again.
                    Backlog.convertToSummarize(entry, transcript: transcript)
                    _ = p.writeNote(meta: meta,
                        summary: "> ⏳ **Summary queued.** Transcript is ready; the AI analysis will be added automatically when Claude Code is available.",
                        transcript: transcript, startedAt: startedAt)
                }

            case "summarize":
                let transcript = (try? String(contentsOf: entry.transcriptFile,
                                              encoding: .utf8)) ?? ""
                if let summary = p.trySummary(transcript: transcript, meta: meta) {
                    _ = p.writeNote(meta: meta, summary: summary,
                                    transcript: transcript, startedAt: startedAt)
                    Backlog.remove(entry); completed += 1
                } else {
                    Backlog.bump(entry)
                }

            default:
                Backlog.remove(entry)
            }
        }
        if completed > 0 { Log.ok("Backlog: completed \(completed) recording(s).") }
        return completed
    }

    private func trySummary(transcript: String, meta: String) -> String? {
        let s = Summarizer(config: config)
        guard s.isConfigured else { return nil }
        return try? s.summarize(transcript: transcript, meta: meta)
    }

    /// After too many attempts, salvage what we have and stop retrying.
    private func finalizeGivenUp(_ entry: Backlog.Entry, meta: String) {
        if entry.meta.stage == "summarize",
           let transcript = try? String(contentsOf: entry.transcriptFile, encoding: .utf8) {
            _ = writeNote(meta: meta,
                summary: "> ⚠️ Summary could not be generated after several retries. The full transcript below is complete; run `claude` once to log in and future calls will summarize automatically.",
                transcript: transcript, startedAt: entry.startedAtDate)
        } else {
            _ = writeNote(meta: meta,
                summary: "> ⚠️ This recording could not be transcribed after several retries (check `ghostie doctor`).",
                transcript: "_(Transcription failed.)_", startedAt: entry.startedAtDate)
        }
        Log.warn("Backlog: gave up on \(entry.dir.lastPathComponent) after \(entry.meta.attempts) attempts.")
    }

    // MARK: Shared steps

    /// Transcribe both tracks, clean per track, merge by timestamp. When
    /// code-switching is enabled the dual-model pipeline replaces the single
    /// whisper pass; per-track cleaning + the timestamp merge are unchanged so
    /// the cleaner and summary see the same shape either way.
    private func transcribeMerge(mic: URL, sys: URL) throws -> [Line] {
        var lines: [Line] = []
        func collect(_ raw: [Transcriber.Segment], _ speaker: String) {
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

        // Codeswitch is taken whenever ≥2 per-language whisper models are
        // installed on disk. With one model, the single-language path runs
        // exactly as it did pre-v2. Users control behaviour by what they
        // install, not by a Settings toggle — the disk IS the whitelist.
        let cs = config.codeSwitch
        let installed = Models.installed(preferredKBVariant: cs.kbWhisperVariant)
        let active = cs.effectiveLanguages(installed: installed)
        if active.count >= 2 {
            Log.info("Code-switching transcription on (languages: "
                + active.joined(separator: "+") + ").")
            let cst = CodeSwitchTranscriber(config: config, installed: installed)
            let (meSegs, partSegs) = try cst.transcribeBoth(me: mic, participants: sys)
            collect(meSegs, "Me")
            collect(partSegs, "Participants")
        } else {
            let transcriber = Transcriber(config: config)
            collect(try transcriber.transcribe(mic, speaker: "Me"), "Me")
            collect(try transcriber.transcribe(sys, speaker: "Participants"), "Participants")
        }
        return lines.sorted { $0.startMs < $1.startMs }
    }

    private func render(_ lines: [Line]) -> String {
        lines.isEmpty
            ? "_(No speech was transcribed.)_"
            : lines.map { "**[\(Self.clock($0.startMs))] \($0.speaker):** \($0.text)" }
                   .joined(separator: "\n\n")
    }

    private func metaBlock(_ startedAt: Date, _ durationMins: String) -> String {
        """
        - Date: \(Self.human.string(from: startedAt))
        - Duration: \(durationMins) minutes
        - Captured locally via ScreenCaptureKit (no bot joined the call)
        """
    }

    private func cleanup(_ sessionDir: URL) {
        if config.keepAudio {
            Log.info("Audio kept at \(sessionDir.path)")
        } else {
            try? FileManager.default.removeItem(at: sessionDir)
        }
    }

    @discardableResult
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
