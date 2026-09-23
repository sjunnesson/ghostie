import Foundation

/// Turns a finished recording into a markdown note:
/// transcribe both tracks → merge by timestamp with speaker labels →
/// summarize → write `<notesFolder>/<date>_<Source>-Call.md` (+ transcript),
/// where Source is the app the call was detected in (Teams / Zoom / Meet).
///
/// If transcription or summarization can't run (whisper missing, Claude Code
/// not logged in, offline, …) the work is queued to the [Backlog] and the
/// recording is kept, so nothing is lost. `drain(config:)` retries the queue
/// whenever Ghostie can process again. After `maxAttempts` failed drains an
/// entry stops being retried, but it is never deleted: the audio/transcript
/// moves to the backlog's `given-up/` folder and the note says where it lives
/// and how to retry it manually (`ghostie process <dir>`).
struct Pipeline {
    let config: Config
    static let maxAttempts = 6

    /// Marker `AudioRecorder` drops into a session directory when a recording
    /// finalizes successfully. It only survives a quit mid-processing —
    /// `cleanup` removes it (or the whole dir) once the session is handled —
    /// so `sweepOrphanedRecordings` can use it to find stranded sessions.
    static let pendingMarker = ".ghostie-pending"

    struct Line {
        let startMs: Int
        let speaker: String
        let text: String
    }

    /// Deterministic timestamp merge across tracks. Swift's sort is not
    /// guaranteed stable, so a bare `startMs` comparison ordered concurrent
    /// cross-talk (equal timestamps) arbitrarily between runs; the
    /// speaker-then-text tie-break makes re-processing a recording
    /// byte-identical. Internal (not private) for the selftest.
    static func merge(_ lines: [Line]) -> [Line] {
        lines.sorted {
            if $0.startMs != $1.startMs { return $0.startMs < $1.startMs }
            if $0.speaker != $1.speaker { return $0.speaker < $1.speaker }
            return $0.text < $1.text
        }
    }

    // MARK: Live processing

    /// `source` label for recordings brought in by `RecordingImporter`.
    /// Names the note (`<stamp>_Imported-Call.md`) and switches the meta
    /// block's origin line; persisted in `Backlog.Meta.source` so a retry
    /// writes the same note.
    static let importedSource = "Imported"

    @discardableResult
    func process(_ rec: AudioRecorder.Result, startedAt: Date,
                 source: String = "Call",
                 roster: MeetingRoster = MeetingRoster()) -> URL? {
        let durationMins = String(format: "%.1f", rec.duration / 60.0)
        Log.info("Processing recording (\(durationMins) min) at \(rec.sessionDir.lastPathComponent)…")
        // Until `cleanup` removes it, this marker is what lets the launch
        // sweep recover the session if Ghostie quits or crashes mid-pipeline.
        // Its body is the source, so a recovered call keeps its note name.
        Self.markPending(rec.sessionDir, source: source)

        let lines: [Line]
        do {
            lines = try transcribeMerge(mic: rec.micWav, sys: rec.systemWav, roster: roster)
        } catch {
            // Killed by a quit: leave the session (and its pending marker)
            // for the next launch's sweep.
            if ChildProcesses.isQuitting { return nil }
            Log.error("Transcription failed: \(error.localizedDescription) — queued to backlog")
            guard Backlog.enqueueAudio(micWav: rec.micWav, systemWav: rec.systemWav,
                                       startedAt: startedAt, durationMins: durationMins,
                                       source: source, roster: roster,
                                       copyingOriginals: config.keepAudio) else {
                // Keep the session dir (and its pending marker): the launch
                // sweep retries it. Deleting it here would lose the call.
                return nil
            }
            // `ghostie process` run on a backlog entry queues it into its own
            // folder; `cleanup` would then delete the only copy of the audio.
            let queuedInPlace = rec.sessionDir.standardizedFileURL.deletingLastPathComponent()
                == URL(fileURLWithPath: Backlog.root).standardizedFileURL
            let url = writeNote(meta: metaBlock(startedAt, durationMins,
                                                mic: rec.micWav, sys: rec.systemWav,
                                                source: source),
                summary: "> ⏳ **Queued.** Transcription wasn't available (\(error.localizedDescription)). Ghostie will process this recording automatically once it can run again.",
                transcript: "_(Pending transcription.)_", startedAt: startedAt,
                source: source)
            if queuedInPlace {
                try? FileManager.default.removeItem(
                    at: rec.sessionDir.appendingPathComponent(Self.pendingMarker))
            } else {
                cleanup(rec.sessionDir)
            }
            return url
        }

        let transcript = render(lines)
        let meta = metaBlock(startedAt, durationMins,
                             mic: rec.micWav, sys: rec.systemWav, source: source)

        if lines.isEmpty {
            let url = writeNote(meta: meta,
                summary: "_No speech detected on either track, so there is nothing to summarize._",
                transcript: transcript, startedAt: startedAt, source: source)
            cleanup(rec.sessionDir)
            return url
        }

        let url = finishWithSummary(startedAt: startedAt, durationMins: durationMins,
                                    meta: meta, transcript: transcript, source: source,
                                    roster: roster)
        if url == nil && ChildProcesses.isQuitting { return nil }   // see above
        cleanup(rec.sessionDir)
        return url
    }

    /// Summarize and write the note; on failure queue a summary-only backlog
    /// entry and write the transcript now with a "summary queued" banner.
    @discardableResult
    private func finishWithSummary(startedAt: Date, durationMins: String,
                                   meta: String, transcript: String,
                                   source: String,
                                   roster: MeetingRoster = MeetingRoster()) -> URL? {
        let summarizer = Summarizer(config: config)
        do {
            guard summarizer.isConfigured else {
                throw NSError(domain: "ghostie", code: 8, userInfo: [
                    NSLocalizedDescriptionKey: "Claude Code CLI not found / not logged in"])
            }
            let summary = try summarizer.summarize(transcript: transcript, meta: meta)
            Log.ok("Summary generated.")
            return writeNote(meta: meta, summary: summary,
                             transcript: transcript, startedAt: startedAt,
                             source: source)
        } catch {
            if ChildProcesses.isQuitting { return nil }
            Log.error("Summary unavailable: \(error.localizedDescription) — queued to backlog")
            Backlog.enqueueTranscript(startedAt: startedAt,
                                      durationMins: durationMins, transcript: transcript,
                                      source: source, roster: roster)
            let banner = "> ⏳ **Summary queued.** Claude Code wasn't available (\(error.localizedDescription)). Ghostie will add the analysis automatically once it can run again — the full transcript below is already complete."
            return writeNote(meta: meta, summary: banner,
                             transcript: transcript, startedAt: startedAt,
                             source: source)
        }
    }

    // MARK: Backlog draining

    /// Try to complete every queued entry. Returns how many were finished.
    /// Safe to call repeatedly; entries that still can't run stay queued.
    ///
    /// Holds the backlog's cross-process lock for the duration: the app and a
    /// `ghostie process-backlog` run used to drain the same entries at once —
    /// double the CPU for tens of minutes, and then one `remove`d a folder the
    /// other was still reading. Whoever finds it held skips this drain.
    @discardableResult
    static func drain(config: Config) -> Int {
        guard !Backlog.isEmpty else { return 0 }
        guard let lock = Backlog.DrainLock() else {
            Log.info("Backlog: another Ghostie process is draining it — skipping this pass.")
            return 0
        }
        defer { lock.release() }
        let entries = Backlog.entries()
        guard !entries.isEmpty else { return 0 }
        let p = Pipeline(config: config)
        Log.info("Backlog: \(entries.count) pending — attempting to process…")
        var completed = 0

        for entry in entries {
            let startedAt = entry.startedAtDate
            let meta = entry.meta.stage == "transcribe"
                ? p.metaBlock(startedAt, entry.meta.durationMins,
                              mic: entry.micWav, sys: entry.systemWav,
                              source: entry.meta.source ?? "Call")
                : p.metaBlock(startedAt, entry.meta.durationMins,
                              source: entry.meta.source ?? "Call")
            // Pre-source entries default to "Teams" — the label their queued
            // note was originally written under, so the note name re-derives
            // identically and the upgrade lands in place.
            let source = entry.meta.source ?? "Teams"

            if entry.meta.attempts >= maxAttempts {
                if p.finalizeGivenUp(entry, meta: meta, source: source) { completed += 1 }
                continue
            }

            switch entry.meta.stage {
            case "transcribe":
                guard let lines = try? p.transcribeMerge(mic: entry.micWav,
                                                         sys: entry.systemWav,
                                                         roster: entry.meta.meetingRoster) else {
                    Backlog.bump(entry)            // whisper still unavailable
                    continue
                }
                let transcript = p.render(lines)
                if lines.isEmpty {
                    _ = p.writeNote(meta: meta,
                        summary: "_No speech detected on either track._",
                        transcript: transcript, startedAt: startedAt, source: source)
                    Backlog.remove(entry); completed += 1
                    continue
                }
                if let summary = p.trySummary(transcript: transcript, meta: meta) {
                    _ = p.writeNote(meta: meta, summary: summary,
                                    transcript: transcript, startedAt: startedAt,
                                    source: source)
                    Backlog.remove(entry); completed += 1
                } else if ChildProcesses.isQuitting {
                    continue          // killed by a quit, not a failed attempt
                } else {
                    // Transcribed OK but summary still down: keep the
                    // transcript so we never re-transcribe this one again.
                    Backlog.convertToSummarize(entry, transcript: transcript)
                    _ = p.writeNote(meta: meta,
                        summary: "> ⏳ **Summary queued.** Transcript is ready; the AI analysis will be added automatically when Claude Code is available.",
                        transcript: transcript, startedAt: startedAt, source: source)
                }

            case "summarize":
                // Unreadable is not empty: summarizing "" would write a note
                // with no transcript and then remove the only copy.
                guard let transcript = try? String(contentsOf: entry.transcriptFile,
                                                   encoding: .utf8) else {
                    Log.warn("Backlog: could not read \(entry.transcriptFile.path) — will retry.")
                    Backlog.bump(entry)
                    continue
                }
                if let summary = p.trySummary(transcript: transcript, meta: meta) {
                    _ = p.writeNote(meta: meta, summary: summary,
                                    transcript: transcript, startedAt: startedAt,
                                    source: source)
                    Backlog.remove(entry); completed += 1
                } else {
                    Backlog.bump(entry)
                }

            default:
                Backlog.remove(entry)
            }
        }
        if completed > 0 { Log.ok("Backlog: completed \(completed) recording(s).") }
        Backlog.pruneGivenUp()
        return completed
    }

    private func trySummary(transcript: String, meta: String) -> String? {
        let s = Summarizer(config: config)
        guard s.isConfigured else { return nil }
        return try? s.summarize(transcript: transcript, meta: meta)
    }

    /// After too many attempts, stop retrying but lose nothing: the entry is
    /// preserved under the backlog's `given-up/` folder and the note tells the
    /// user where it lives and how to retry manually. Returns true when the
    /// entry left the queue (false leaves it queued for the next drain).
    private func finalizeGivenUp(_ entry: Backlog.Entry, meta: String,
                                 source: String) -> Bool {
        // Read before the move below relocates the file.
        let transcript = entry.meta.stage == "summarize"
            ? (try? String(contentsOf: entry.transcriptFile, encoding: .utf8)) : nil
        guard let preserved = Backlog.giveUp(entry) else { return false }
        if entry.meta.stage == "summarize" {
            _ = writeNote(meta: meta,
                summary: "> ⚠️ Summary could not be generated after several retries. The full transcript below is complete; run `claude` once to log in and future calls will summarize automatically. (The transcript is also preserved at `\(preserved.path)`.)",
                transcript: transcript ?? "_(Transcript file could not be read — preserved at `\(preserved.path)`.)_",
                startedAt: entry.startedAtDate, source: source)
        } else {
            _ = writeNote(meta: meta,
                summary: "> ⚠️ This recording could not be transcribed after several retries (check `ghostie doctor`). Nothing is lost: the audio is preserved at `\(preserved.path)` — once transcription works again, run `ghostie process \"\(preserved.path)\"` to transcribe it.",
                transcript: "_(Transcription failed — audio preserved at `\(preserved.path)`.)_",
                startedAt: entry.startedAtDate, source: source)
        }
        Log.warn("Backlog: gave up on \(entry.dir.lastPathComponent) after \(entry.meta.attempts) attempts — preserved at \(preserved.path).")
        return true
    }

    // MARK: Orphan sweep

    /// Recover session directories stranded by a quit mid-processing: any dir
    /// in the recordings folder that still carries the `.ghostie-pending`
    /// marker plus recorded audio is moved into the backlog at the
    /// `transcribe` stage and gets the usual queued-banner note, so the next
    /// drain picks it up. Dirs without the marker — `keepAudio` leftovers from
    /// already-processed calls, or a recording still in progress (the recorder
    /// only writes the marker on successful finalize) — are never touched.
    /// Synchronous; called once at launch on the engine's serial work queue.
    /// Returns how many sessions were swept.
    static func sweepOrphanedRecordings(config: Config) -> Int {
        CodeSwitchTranscriber.sweepScratch()
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: URL(fileURLWithPath: config.workDir),
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey])
        else { return 0 }
        let p = Pipeline(config: config)
        var swept = 0
        for dir in items {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  fm.fileExists(atPath: dir.appendingPathComponent(pendingMarker).path)
            else { continue }
            let mic = dir.appendingPathComponent("me.wav")
            let sys = dir.appendingPathComponent("participants.wav")
            guard fm.fileExists(atPath: mic.path) || fm.fileExists(atPath: sys.path)
            else { continue }

            // Session dirs are named with AudioRecorder's start-time stamp;
            // fall back to the directory's mtime for anything renamed.
            let startedAt = AudioRecorder.stampFormatter.date(from: dir.lastPathComponent)
                ?? (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                ?? Date()
            let durationMins = String(format: "%.1f", wavSeconds(mic, sys) / 60.0)
            Log.info("Recovered orphaned recording \(dir.lastPathComponent) — queued to backlog.")
            // `Pipeline.process` writes the call's source into the marker; a
            // session that died before processing began has an empty one and
            // gets the generic label.
            let marked = (try? String(contentsOf: dir.appendingPathComponent(pendingMarker),
                                      encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let source = marked.isEmpty ? "Call" : marked
            guard Backlog.enqueueAudio(micWav: mic, systemWav: sys,
                                       startedAt: startedAt, durationMins: durationMins,
                                       source: source,
                                       copyingOriginals: config.keepAudio) else { continue }
            _ = p.writeNote(meta: p.metaBlock(startedAt, durationMins),
                summary: "> ⏳ **Queued.** Ghostie quit before this recording could be processed. It has been queued and will be processed automatically.",
                transcript: "_(Pending transcription.)_", startedAt: startedAt,
                source: source)
            p.cleanup(dir)
            swept += 1
        }
        return swept
    }

    /// Best-effort duration of a session from its largest WAV. `WavWriter`
    /// only produces 16 kHz mono 16-bit PCM, so payload is 32,000 bytes/s
    /// after the 44-byte header.
    private static func wavSeconds(_ wavs: URL...) -> Double {
        let bytes = wavs.compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.size] as? Int
        }.max() ?? 0
        return Double(max(0, bytes - 44)) / 32_000.0
    }

    // MARK: Shared steps

    /// Transcribe both tracks, clean per track, merge by timestamp. When
    /// code-switching is enabled the dual-model pipeline replaces the single
    /// whisper pass; per-track cleaning + the timestamp merge are unchanged so
    /// the cleaner and summary see the same shape either way.
    /// Writes the post-clean segments beside their WAV, in whisper's own
    /// `-oj` shape, when `GHOSTIE_DUMP_SEGMENTS` is set.
    ///
    /// These are what diarization actually sees, and nothing else can produce
    /// them: the decode runs over a *speech-stitched* WAV and maps back, so
    /// re-running `whisper-cli` on the original file gives a different set
    /// entirely — measured on the 2026-09-11 call, 6 347 segments at a 1.0 s
    /// median against the pipeline's 577 at ~6.5 s. Tuning diarization
    /// against that would be tuning against the wrong input.
    /// `ghostie diarize-probe <wav> <wav>.cleaned.json` then reproduces a
    /// call's clustering exactly, offline, as often as you like.
    ///
    /// Off by default: a call already keeps its audio, and this would add a
    /// file per track to every session for the sake of an investigation that
    /// is not usually running.
    static func dumpSegments(_ segments: [Transcriber.Segment], beside wav: URL) {
        guard ProcessInfo.processInfo.environment["GHOSTIE_DUMP_SEGMENTS"] != nil,
              !segments.isEmpty else { return }
        let rows: [[String: Any]] = segments.map {
            ["text": $0.text,
             "offsets": ["from": $0.startMs, "to": $0.endMs ?? $0.startMs]]
        }
        let url = wav.deletingPathExtension().appendingPathExtension("cleaned.json")
        guard let data = try? JSONSerialization.data(withJSONObject: ["transcription": rows],
                                                     options: [.prettyPrinted]),
              (try? data.write(to: url)) != nil else {
            Log.warn("Could not write \(url.lastPathComponent).")
            return
        }
        Log.info("Dumped \(segments.count) post-clean segments → \(url.lastPathComponent)")
    }

    private func transcribeMerge(mic: URL, sys: URL,
                                 roster: MeetingRoster = MeetingRoster()) throws -> [Line] {
        // One streamed pass per track, so the cleaner can ask whether a
        // segment's own span of the recording carried any audio at all. Only
        // built when the guard is on — it is the only thing that reads it.
        func envelope(_ wav: URL) -> WavLevel.Envelope? {
            guard config.cleanTranscript else { return nil }
            return WavLevel.envelope(wav)
        }

        // Whisper's own `endMs` rides along: diarization embeds these spans,
        // and rebuilding them from the next segment's start swallows the
        // pause a speaker change lives in.
        func cleaned(_ raw: [Transcriber.Segment], _ speaker: String,
                     wav: URL, audio: WavLevel.Envelope?) -> [Transcriber.Segment] {
            let out: [Transcriber.Segment]
            if config.cleanTranscript {
                let (cleanSegs, stats) = TranscriptCleaner.clean(raw, audio: audio)
                if stats.removed > 0 || stats.silenceGateStoodDown > 0 {
                    Log.info("\(speaker): \(stats.summary)")
                }
                out = cleanSegs.map {
                    Transcriber.Segment(startMs: $0.startMs, text: $0.text, endMs: $0.endMs)
                }
            } else {
                out = raw
            }
            Self.dumpSegments(out, beside: wav)
            return out
        }

        var me: [Transcriber.Segment]
        var part: [Transcriber.Segment]

        // A single-track recording — `ghostie process` on an imported file,
        // or a session whose other WAV was never written — has no second
        // track. The health warning above reads the real URLs (a track that
        // does not exist is not a track that recorded nothing); down here a
        // silent stub stands in for it so both transcription paths run
        // unchanged and the missing side simply contributes no lines.
        let haveMic = FileManager.default.fileExists(atPath: mic.path)
        let haveSys = FileManager.default.fileExists(atPath: sys.path)
        let mic = haveMic ? mic : Self.silentStub(beside: mic)
        let sys = haveSys ? sys : Self.silentStub(beside: sys)

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
            me = cleaned(meSegs, "Me", wav: mic, audio: envelope(mic))
            part = cleaned(partSegs, "Participants", wav: sys, audio: envelope(sys))
        } else {
            let transcriber = Transcriber(config: config)
            me = haveMic
                ? cleaned(try transcriber.transcribe(mic, speaker: "Me"),
                          "Me", wav: mic, audio: envelope(mic))
                : []
            part = haveSys
                ? cleaned(try transcriber.transcribe(sys, speaker: "Participants"),
                          "Participants", wav: sys, audio: envelope(sys))
                : []
        }

        let partLabels = diarizeParticipants(part, wav: sys)

        // Cross-track echo guard: without headphones the speakers' output
        // re-enters the mic, so Me duplicates Participants. Per-track cleaning
        // can't see this; it has to run here, between clean and merge.
        if config.cleanTranscript {
            // The echo guard reads text and start times only, and the Me
            // track's spans have no consumer past this point — diarization
            // runs on Participants alone — so they stop here rather than
            // being threaded through a module with its own fixtures.
            let (deEchoed, stats) = EchoSuppressor.suppress(
                me: me.map { (startMs: $0.startMs, text: $0.text) },
                participants: part.map { (startMs: $0.startMs, text: $0.text) })
            if stats.engaged {
                Log.info(stats.summary)
                me = deEchoed.map { Transcriber.Segment(startMs: $0.startMs, text: $0.text) }
            }
        }

        var lines = me.map { Line(startMs: $0.startMs, speaker: "Me", text: $0.text) }
        lines += part.map { Line(startMs: $0.startMs, speaker: partLabels[$0.startMs] ?? "Participants",
                                 text: $0.text) }
        // Readability, in order: join whisper's mid-sentence segment splits
        // into turns, then put the punctuation back if whisper dropped into
        // its unpunctuated register. Both run before naming so the naming
        // prompt — and the summary built on it — see the readable transcript.
        return named(refined(Self.merge(lines)), roster: roster)
    }

    /// A 1.5 s silent 16 kHz mono WAV written next to a track that does not
    /// exist (`<name>.empty.wav`). Long enough that whisper's VAD pass accepts
    /// it (it refuses inputs under a second), short enough that nothing can
    /// be decoded from it: VAD finds no speech, so the code-switch path
    /// returns no segments for the track.
    private static func silentStub(beside wav: URL) -> URL {
        let stub = wav.deletingPathExtension().appendingPathExtension("empty.wav")
        let rate: UInt32 = 16_000
        let bytes = Int(rate) * 3 / 2 * 2   // 1.5 s of 16-bit samples
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + bytes))
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(rate); u32(rate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(UInt32(bytes))
        data.append(Data(count: bytes))
        try? data.write(to: stub)
        Log.info("\(wav.lastPathComponent) not present — treating that track as silent.")
        return stub
    }

    /// Coalesce segments into turns, then repunctuate when the transcript
    /// needs it. Skipped entirely by `cleanTranscript: false`, which is the
    /// existing "give me exactly what whisper said" switch.
    private func refined(_ lines: [Line]) -> [Line] {
        guard config.cleanTranscript else { return lines }
        let turns = TranscriptRefiner.coalesce(lines)
        if turns.count != lines.count {
            Log.info("Turn merge: \(lines.count) → \(turns.count) turns.")
        }
        guard config.restorePunctuation,
              TranscriptRefiner.needsRestoration(turns) else { return turns }

        // Punctuation is the only thing that makes a sentence boundary
        // visible, so the model is shown blocks several turns long rather
        // than the readable turns above: a 40-word cut lands mid-clause and
        // no later pass can tell it from a real one. `split` cuts the turns
        // afterwards, at the sentences that came back.
        let blocks = TranscriptRefiner.blocks(
            lines, maxTurnWords: TranscriptRefiner.blockWords)
        let (restored, stats) = TranscriptRefiner.restore(
            blocks.map(\.line), provider: Summarizer(config: config).punctuationProvider)
        Log.info(stats.summary)
        let out = TranscriptRefiner.split(restored, blocks: blocks)
        let ended = Int(TranscriptRefiner.terminalFraction(out) * 100)
        Log.info("Turn split: \(blocks.count) blocks → \(out.count) turns "
            + "(\(ended)% end a sentence).")
        return out
    }

    /// Splits the Participants track into individual speakers.
    ///
    /// Only that track: "Me" is the local microphone and holds exactly one
    /// person by construction, so diarizing it could only invent speakers who
    /// are not there. This is also why Ghostie needs a diarizer far less than
    /// a single-stream recorder does — the hard half of the problem, "which
    /// side is this", is already answered by the capture itself.
    ///
    /// Returns a label per segment start time. Empty on every unavailable or
    /// inconclusive path — no model, no ONNX runtime, a short track — which
    /// leaves the plural "Participants" label in place, because a track
    /// nobody could split may still hold a roomful of people.
    ///
    /// A track that *was* split, even into one voice, is labelled
    /// "Participant N" instead. That difference is the whole reason this
    /// returns what it does: on the 2026-09-08 Meet call the far end was one
    /// person and the transcript called them "Participants" for two hours,
    /// and the summary then wrote *"a close friend (labeled 'Participants')"*
    /// into its prose — the model had no way to know it was reading a track
    /// name rather than a name.
    private func diarizeParticipants(_ segments: [Transcriber.Segment],
                                     wav: URL) -> [Int: String] {
        guard config.diarization, segments.count > 1 else { return [:] }
        guard let embedder = SpeakerEmbedder.load(config: config) else { return [:] }
        defer { embedder.shutdown() }
        // Converted straight away so the Int16 bytes are released before
        // the (minutes-long) embedding pass rather than held beside the Float
        // copy for all of it — ~230 MB on a two-hour track.
        guard let samples = (try? AudioStitcher.readPCM(wav))
                .map(SpeakerDiarizer.floatSamples) else { return [:] }

        // Whisper's own span per segment, which the cleaner carries through.
        // Only a segment that never had one falls back to the next segment's
        // start — see `Transcriber.Segment.endMs`: that fallback span
        // swallows the pause between two segments, and a speaker change lives
        // in exactly that pause, so the embedding picks up the leading edge of
        // whoever spoke next. Doing it for *every* segment is how four voices
        // clustered into three on the 2026-09-11 Zoom call.
        let input = segments.enumerated().map { i, s in
            Transcriber.Segment(
                startMs: s.startMs, text: s.text,
                endMs: s.endMs ?? (i + 1 < segments.count ? segments[i + 1].startMs : nil))
        }
        let t0 = Date()
        guard let a = SpeakerDiarizer().diarize(
                segments: input,
                samples: samples,
                embedder: embedder) else {
            Log.info("Diarization: too little on the Participants track to judge on "
                + "— keeping the generic label.")
            return [:]
        }
        Log.info(a.summary + String(format: " in %.0fs", Date().timeIntervalSince(t0)))
        var labels: [Int: String] = [:]
        for (i, speaker) in a.speakers.enumerated() {
            guard let speaker else { continue }
            labels[segments[i].startMs] = "Participant \(speaker + 1)"
        }
        return labels
    }

    /// Replaces placeholder labels with real names, when they can be
    /// established from the conversation. Anything that cannot be named keeps
    /// its placeholder.
    private func named(_ lines: [Line], roster: MeetingRoster = MeetingRoster()) -> [Line] {
        var labels: [String] = []
        for l in lines where !labels.contains(l.speaker) { labels.append(l.speaker) }
        guard let naming = SpeakerNamer(config: config)
                .name(labels: labels, transcript: render(lines), roster: roster),
              !naming.names.isEmpty else { return lines }
        Log.info(naming.summary)
        return lines.map {
            guard let name = naming.names[$0.speaker] else { return $0 }
            return Line(startMs: $0.startMs, speaker: name, text: $0.text)
        }
    }

    func render(_ lines: [Line]) -> String {
        lines.isEmpty
            ? "_(No speech was transcribed.)_"
            : lines.map { "**[\(Self.clock($0.startMs))] \($0.speaker):** \($0.text)" }
                   .joined(separator: "\n\n")
    }

    private func metaBlock(_ startedAt: Date, _ durationMins: String,
                           mic: URL? = nil, sys: URL? = nil,
                           source: String = "Call") -> String {
        // An imported file was never captured by Ghostie; saying it was
        // would be the meta block's first lie, and the summarizer reads it.
        let origin = source == Self.importedSource
            ? "Imported audio file, transcribed locally. There is no separate \"Me\" speaker in this recording: the reader is one of the numbered participants, so do not list \"You\" or \"Me\" as a participant of their own."
            : "Captured locally via ScreenCaptureKit (no bot joined the call)"
        var block = """
        - Date: \(Self.human.string(from: startedAt))
        - Duration: \(durationMins) minutes
        - \(origin)
        """
        if let warning = Self.trackHealthWarning(mic: mic, sys: sys) {
            block += "\n- ⚠️ \(warning)"
        }
        return block
    }

    /// Names a track that recorded nothing while the other one recorded a
    /// conversation. This is the last line of defence against shipping a
    /// half-recorded call as a complete one: it runs on the finished WAVs, so
    /// it covers every route to a note — live, backlog drain, orphan sweep and
    /// `ghostie process` — regardless of which capture path failed or why.
    ///
    /// Deliberately hard to trip. A track only counts as broken when it is
    /// digitally silent (or all but), *and* the other track is carrying real
    /// speech — so a muted participant, a listener who never spoke, and a call
    /// that was quiet at both ends all pass without comment. The line goes
    /// into the meta block, which is also handed to the summarizer, so the
    /// analysis knows it is working from one side of the conversation.
    static func trackHealthWarning(mic: URL?, sys: URL?) -> String? {
        guard let mic, let sys,
              let me = WavLevel.probe(mic), let them = WavLevel.probe(sys) else {
            return nil
        }
        // Both silent = nothing was said; the "no speech detected" path already
        // covers that and says it better.
        func broken(_ track: WavLevel.Stats, against other: WavLevel.Stats) -> Bool {
            other.activeFraction > 0.05
                && (track.isDigitalSilence || track.activeFraction < 0.005)
        }
        let advice = "Check System Settings ▸ Privacy & Security ▸ Microphone and which input device is selected."
        if broken(me, against: them) {
            Log.warn("'Me' track recorded no audio (peak \(me.peak), \(String(format: "%.2f", me.activeFraction * 100))% active) while 'Participants' carried speech — the note covers only the other participants.")
            return "**Your microphone recorded nothing on this call.** This note and transcript cover only the other participants — everything you said is missing. \(advice)"
        }
        if broken(them, against: me) {
            Log.warn("'Participants' track recorded no audio (peak \(them.peak)) while 'Me' carried speech — the note covers only the local speaker.")
            return "**The other participants' audio was not captured.** This note and transcript cover only your own side of the call."
        }
        return nil
    }

    /// Quit with a call still live: queue it rather than run a pipeline that
    /// takes minutes to tens of minutes while the app hangs on "Finishing
    /// up…". Moves the audio into the backlog (a rename), writes the queued
    /// note so the call is visibly saved, and the next launch's drain does the
    /// rest. If the enqueue fails the session keeps its pending marker and the
    /// launch sweep picks it up instead.
    func queueForLater(_ rec: AudioRecorder.Result, startedAt: Date, source: String,
                       roster: MeetingRoster) {
        let durationMins = String(format: "%.1f", rec.duration / 60.0)
        Self.markPending(rec.sessionDir, source: source)
        guard Backlog.enqueueAudio(micWav: rec.micWav, systemWav: rec.systemWav,
                                   startedAt: startedAt, durationMins: durationMins,
                                   source: source, roster: roster,
                                   copyingOriginals: config.keepAudio) else { return }
        _ = writeNote(meta: metaBlock(startedAt, durationMins, source: source),
            summary: "> ⏳ **Queued.** Ghostie was quit while this call was recording. The recording is saved and will be transcribed automatically the next time Ghostie runs.",
            transcript: "_(Pending transcription.)_", startedAt: startedAt, source: source)
        cleanup(rec.sessionDir)
    }

    /// Mark `sessionDir` as holding audio that has not yet become a note or a
    /// backlog entry. `AudioRecorder.stop` writes it empty once the WAVs are
    /// finalized; `process` rewrites it with the source.
    static func markPending(_ sessionDir: URL, source: String = "") {
        try? Data(source.utf8).write(
            to: sessionDir.appendingPathComponent(pendingMarker), options: .atomic)
    }

    /// The session has been fully handled (note written and/or audio queued):
    /// drop the `.ghostie-pending` marker so the launch-time orphan sweep
    /// never re-queues this directory, then honor `keepAudio`.
    private func cleanup(_ sessionDir: URL) {
        try? FileManager.default.removeItem(
            at: sessionDir.appendingPathComponent(Self.pendingMarker))
        if config.keepAudio {
            Log.info("Audio kept at \(sessionDir.path)")
        } else {
            try? FileManager.default.removeItem(at: sessionDir)
        }
    }

    /// `source` is the app label ("Teams" / "Zoom" / "Meet" / "Test", or the
    /// generic "Call"): it names the file (`<stamp>_Zoom-Call.md`) and titles
    /// the note. Required (no default) so every caller decides deliberately —
    /// backlog paths must re-derive the exact label the queued note was
    /// written under for the in-place upgrade to land.
    @discardableResult
    private func writeNote(meta: String, summary: String,
                           transcript: String, startedAt: Date,
                           source: String) -> URL? {
        let folder = URL(fileURLWithPath: config.notesFolder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        // "Zoom Call"; the bare generic label stays "Call" (never "Call-Call").
        let title = source == "Call" ? "Call" : "\(source) Call"
        let base = Self.noteBaseName(startedAt: startedAt, source: source)
        let noteURL = folder.appendingPathComponent(base + ".md")

        var doc = """
        # \(title) — \(Self.human.string(from: startedAt))

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
            // Index after the note lands, not before: the record points at
            // the note, so a failed write must not leave the index claiming a
            // call that has no note. Every route to a note — live, backlog
            // drain, orphan sweep, `process`, `import` — comes through here,
            // which is why this is the only place that indexes.
            TranscriptIndex.write(
                id: base, startedAt: startedAt, source: source,
                durationMins: TranscriptIndex.duration(fromMeta: meta),
                notePath: noteURL.path,
                transcriptPath: config.saveTranscript
                    ? folder.appendingPathComponent(base + "_transcript.md").path
                    : nil,
                transcript: transcript)
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

    /// Seconds precision so two calls in the same minute (short call + redial,
    /// a test run next to a real call) can't overwrite each other's notes,
    /// while the note name stays a pure function of `startedAt` + `source` —
    /// backlog retries re-derive both from meta.json and upgrade the queued
    /// note in place.
    /// `2026-09-21_20-59-58_Zoom-Call` — the note's basename, and so the
    /// index id. A pure function of `startedAt` + source (see `writeNote`).
    static func noteBaseName(startedAt: Date, source: String) -> String {
        // "Zoom" → "Zoom-Call"; the bare generic label stays "Call".
        let token = source == "Call" ? "Call" : "\(source)-Call"
        return fileStamp.string(from: startedAt) + "_" + token
    }

    private static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return f
    }()
}
