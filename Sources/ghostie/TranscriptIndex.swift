import Foundation

/// Machine-readable sidecars for the markdown notes, so `ghostie mcp` can
/// answer questions about a call without parsing prose back into facts.
///
/// One JSON file per call under `~/.ghostie/index/<id>.json`, **not** next to
/// the note. The notes folder is the user's — frequently an Obsidian vault or
/// an iCloud folder — and derived data does not belong in it. Keeping the
/// index out of there also means moving or renaming the notes folder costs
/// nothing but a re-index, and nothing Ghostie writes here can be mistaken
/// for a document the user authored.
///
/// The index is **derived and disposable**: `ghostie index` rebuilds the whole
/// thing from the notes on disk. That is what makes it safe to change the
/// schema — bump `CallRecord.schema`, and records written by an older build
/// are ignored until they are rebuilt, rather than being read as if the fields
/// still meant the same thing.
///
/// The summary is deliberately *not* stored here. The note is the canonical
/// artifact and people edit it (that is the point of writing markdown into a
/// vault); a copy in the index would silently go stale and the MCP server
/// would start quoting a version of the note the user has already rewritten.
/// So the index owns what markdown cannot express — the turn structure — and
/// the summary is read from the note at the moment it is asked for.
enum TranscriptIndex {

    static let root = "\(NSHomeDirectory())/.ghostie/index"

    /// Bump when the meaning of a stored field changes. `load` drops records
    /// written under a different number, so a stale index degrades to "not
    /// indexed yet" rather than to wrong answers.
    static let currentSchema = 1

    // MARK: Records

    struct Turn: Codable, Sendable {
        /// Offset from the start of the recording. Seconds resolution: the
        /// note renders `MM:SS` and this is recovered from that rendering, so
        /// claiming milliseconds would be claiming precision that is not here.
        let ms: Int
        let speaker: String
        let text: String
    }

    struct CallRecord: Codable, Sendable {
        let schema: Int
        /// The note's basename — `2026-09-21_20-59-58_Zoom-Call`. Already
        /// unique (seconds precision) and already a pure function of
        /// `startedAt` + source, so the note naming scheme is the ID scheme.
        let id: String
        let startedAt: Date
        /// "Zoom" / "Teams" / "Meet" / "Imported" / "Call".
        let source: String
        let durationMins: String
        let notePath: String
        let transcriptPath: String?
        /// Distinct speakers in order of first appearance. After the naming
        /// pass these are real names; without it, "Me" / "Participant N".
        let speakers: [String]
        let turnCount: Int
        let turns: [Turn]
    }

    /// Everything about a call except its turns. `list_calls` and search want
    /// the metadata for every call on disk and the turns of almost none of
    /// them, and decoding a 50-minute transcript to read its date back is the
    /// difference between a listing that is instant and one that is not.
    struct CallSummary: Codable, Sendable {
        let schema: Int
        let id: String
        let startedAt: Date
        let source: String
        let durationMins: String
        let notePath: String
        let transcriptPath: String?
        let speakers: [String]
        let turnCount: Int
    }

    // MARK: Coding

    /// ISO-8601 carrying this machine's UTC offset rather than a bare `Z`.
    ///
    /// The instant is the same either way — this is about the record being
    /// readable. A meeting's time is a wall-clock fact about the author's day,
    /// and `2026-09-21T18:59:58Z` for a call whose own note is titled 20:59 is
    /// a thing you have to stop and convert. It is the *machine's* offset, not
    /// the one the call was recorded in: the note name carries no zone, so a
    /// note written abroad is read back in the zone that reads it.
    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone.current
        return f
    }()

    static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(dateFormatter.string(from: date))
        }
        return e
    }

    static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let s = try decoder.singleValueContainer().decode(String.self)
            guard let date = dateFormatter.date(from: s) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath,
                          debugDescription: "Not an ISO-8601 date: \(s)"))
            }
            return date
        }
        return d
    }

    // MARK: Parsing the rendered transcript

    /// Recover turns from the transcript markdown `Pipeline.render` writes:
    /// `**[MM:SS] Speaker:** text`.
    ///
    /// Parsing back what we just rendered looks redundant next to threading
    /// `[Pipeline.Line]` through, but it is the only approach that covers
    /// every note: the backlog's summarize stage re-reads its transcript from
    /// disk and never holds the lines at all, and the notes already written
    /// before this existed have nothing *but* the markdown. One parser, used
    /// by both the live write and `ghostie index`, means the freshly indexed
    /// call and the back-filled one are byte-identical records.
    ///
    /// Minutes are not clamped to two digits — `clock()` prints 90:05 for a
    /// call an hour and a half in, and reading that as invalid would silently
    /// drop every turn past the first hour.
    static func parseTurns(_ rendered: String) -> [Turn] {
        var turns: [Turn] = []
        for rawLine in rendered.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            if let turn = parseTurn(line) {
                turns.append(turn)
            } else if !turns.isEmpty, !line.hasPrefix("_(") {
                // A turn whose text carried a newline: keep the words with the
                // speaker who said them rather than discarding the line.
                let last = turns.removeLast()
                turns.append(Turn(ms: last.ms, speaker: last.speaker,
                                  text: last.text + " " + line))
            }
        }
        return turns
    }

    /// `**[MM:SS] Speaker:** text` → one turn, or nil if the line is anything
    /// else (the meta block, a rule, the "no speech" placeholder).
    private static func parseTurn(_ line: String) -> Turn? {
        guard line.hasPrefix("**["),
              let closeBracket = line.firstIndex(of: "]") else { return nil }

        let clock = line[line.index(line.startIndex, offsetBy: 3)..<closeBracket]
        let parts = clock.split(separator: ":")
        guard parts.count == 2,
              let minutes = Int(parts[0]), let seconds = Int(parts[1]),
              minutes >= 0, seconds >= 0, seconds < 60 else { return nil }

        // The speaker runs from after "] " to the closing "**" of the bold
        // run. Searching for ":**" would break on a speaker whose transcript
        // text begins with a colon, so anchor on the bold terminator.
        let afterBracket = line.index(after: closeBracket)
        let rest = line[afterBracket...].drop(while: { $0 == " " })
        guard let boldEnd = rest.range(of: "**") else { return nil }
        var speaker = String(rest[rest.startIndex..<boldEnd.lowerBound])
        guard speaker.hasSuffix(":") else { return nil }
        speaker.removeLast()
        speaker = speaker.trimmingCharacters(in: .whitespaces)
        guard !speaker.isEmpty else { return nil }

        let text = String(rest[boldEnd.upperBound...])
            .trimmingCharacters(in: .whitespaces)
        return Turn(ms: (minutes * 60 + seconds) * 1000, speaker: speaker, text: text)
    }

    /// Distinct speakers, in the order they first spoke.
    static func speakers(in turns: [Turn]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for turn in turns where !seen.contains(turn.speaker) {
            seen.insert(turn.speaker)
            ordered.append(turn.speaker)
        }
        return ordered
    }

    /// Pull `- Duration: 50.1 minutes` back out of the meta block Pipeline
    /// just built. Cheaper than threading the value through eleven call sites
    /// for a string that is already, verbatim, in hand.
    static func duration(fromMeta meta: String) -> String {
        for line in meta.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("- Duration:") else { continue }
            return trimmed.dropFirst("- Duration:".count)
                .replacingOccurrences(of: "minutes", with: "")
                .trimmingCharacters(in: .whitespaces)
        }
        return ""
    }

    // MARK: Writing

    /// Index one call. Never throws and never fails a note write: the note is
    /// the product and the index is a convenience for the MCP server, so a
    /// full disk costs the user a search result, not their meeting notes.
    @discardableResult
    static func write(id: String, startedAt: Date, source: String,
                      durationMins: String, notePath: String,
                      transcriptPath: String?, transcript: String) -> URL? {
        let turns = parseTurns(transcript)
        let record = CallRecord(
            schema: currentSchema, id: id, startedAt: startedAt, source: source,
            durationMins: durationMins, notePath: notePath,
            transcriptPath: transcriptPath, speakers: speakers(in: turns),
            turnCount: turns.count, turns: turns)
        return write(record)
    }

    @discardableResult
    static func write(_ record: CallRecord) -> URL? {
        let dir = URL(fileURLWithPath: root)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(record.id + ".json")
        do {
            try makeEncoder().encode(record).write(to: url, options: .atomic)
            return url
        } catch {
            Log.warn("Could not index \(record.id): \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: Reading

    static func url(for id: String) -> URL {
        URL(fileURLWithPath: root).appendingPathComponent(id + ".json")
    }

    /// One full record, turns included. Nil when the call was never indexed,
    /// when the record predates the current schema, or when the note it
    /// describes is gone (deleted or moved out of the notes folder) — a record
    /// pointing at a file that no longer exists is not a call the user has.
    static func load(id: String) -> CallRecord? {
        guard let data = try? Data(contentsOf: url(for: id)),
              let record = try? makeDecoder().decode(CallRecord.self, from: data),
              record.schema == currentSchema,
              FileManager.default.fileExists(atPath: record.notePath)
        else { return nil }
        return record
    }

    /// Every indexed call, newest first, without decoding any turns.
    static func summaries() -> [CallSummary] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        let decoder = makeDecoder()
        var out: [CallSummary] = []
        for name in names where name.hasSuffix(".json") {
            let path = URL(fileURLWithPath: root).appendingPathComponent(name)
            guard let data = try? Data(contentsOf: path),
                  let summary = try? decoder.decode(CallSummary.self, from: data),
                  summary.schema == currentSchema,
                  fm.fileExists(atPath: summary.notePath)
            else { continue }
            out.append(summary)
        }
        return out.sorted { $0.startedAt > $1.startedAt }
    }

    /// The written analysis, read from the note itself so hand edits are
    /// what the MCP server serves.
    ///
    /// `writeNote` lays the note out as `# title` / meta / `---` / summary /
    /// `---` / `## Full Transcript`. Taking everything between the first rule
    /// and the transcript heading survives the summary containing its own
    /// `##` headings (it always does) and its own `---` rules (it may).
    static func summaryText(ofNoteAt path: String) -> String? {
        guard let doc = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        guard let firstRule = doc.range(of: "\n---\n") else { return nil }
        let afterMeta = doc[firstRule.upperBound...]
        let end = afterMeta.range(of: "\n---\n\n## Full Transcript")?.lowerBound
            ?? afterMeta.endIndex
        let summary = afterMeta[afterMeta.startIndex..<end]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    // MARK: Rebuilding

    /// Rebuild the index from the notes on disk. Covers every call written
    /// before the index existed, and repairs one that drifted.
    ///
    /// The transcript is preferred from the `_transcript.md` sidecar note and
    /// falls back to the copy embedded in the note itself, because
    /// `saveTranscript = false` puts it only in the note.
    ///
    /// Returns (indexed, skipped).
    @discardableResult
    static func rebuild(notesFolder: String) -> (indexed: Int, skipped: Int) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: notesFolder) else {
            Log.error("Notes folder not readable: \(notesFolder)")
            return (0, 0)
        }
        let folder = URL(fileURLWithPath: notesFolder)
        var indexed = 0, skipped = 0

        // `_transcript` anywhere, not just as the suffix: a transcript the
        // user has copied or renamed ("…_transcript (deduplicated).md" is a
        // real example from this machine) is still a transcript, and
        // indexing one as if it were a call invents a meeting that never
        // happened — with the transcript's own header parsed as its summary.
        for name in names.sorted() where isNoteFile(name) {
            let id = String(name.dropLast(3))
            guard let parsed = parseNoteName(id) else { skipped += 1; continue }
            let notePath = folder.appendingPathComponent(name).path

            let transcriptURL = folder.appendingPathComponent(id + "_transcript.md")
            let hasTranscriptFile = fm.fileExists(atPath: transcriptURL.path)
            let body = hasTranscriptFile
                ? (try? String(contentsOf: transcriptURL, encoding: .utf8))
                : (try? String(contentsOfFile: notePath, encoding: .utf8))
            guard let body else { skipped += 1; continue }

            let turns = parseTurns(body)
            let record = CallRecord(
                schema: currentSchema, id: id, startedAt: parsed.startedAt,
                source: parsed.source,
                durationMins: durationFromNote(at: notePath),
                notePath: notePath,
                transcriptPath: hasTranscriptFile ? transcriptURL.path : nil,
                speakers: speakers(in: turns), turnCount: turns.count, turns: turns)
            if write(record) != nil { indexed += 1 } else { skipped += 1 }
        }
        return (indexed, skipped)
    }

    /// Is this filename one of Ghostie's call notes (rather than one of its
    /// transcripts, or a file someone else put in the folder)?
    ///
    /// `_transcript` anywhere, not just as the suffix: a transcript the user
    /// has copied or renamed ("…_transcript (deduplicated).md" is a real
    /// example) is still a transcript, and indexing one as if it were a call
    /// invents a meeting that never happened — with the transcript's own
    /// header read as its summary. Shared with the MCP server's staleness
    /// check so the two can't disagree about what counts as a note.
    static func isNoteFile(_ name: String) -> Bool {
        name.hasSuffix(".md") && !name.contains("_transcript")
    }

    /// "Zoom" → "Zoom call"; the generic "Call" source stays "Call", never
    /// "Call call".
    static func title(for source: String) -> String {
        source.caseInsensitiveCompare("Call") == .orderedSame ? "Call" : "\(source) call"
    }

    private static func durationFromNote(at path: String) -> String {
        guard let doc = try? String(contentsOfFile: path, encoding: .utf8) else { return "" }
        return duration(fromMeta: doc)
    }

    /// `2026-09-21_20-59-58_Zoom-Call` → the date and "Zoom".
    ///
    /// The stamp is written in the machine's local time zone, so it is read
    /// back in the machine's local time zone; a note carried across a time
    /// zone change keeps the clock time its own title shows.
    static func parseNoteName(_ id: String) -> (startedAt: Date, source: String)? {
        // "yyyy-MM-dd_HH-mm-ss" is exactly 19 characters, then "_<token>".
        guard id.count > 20 else { return nil }
        let stampEnd = id.index(id.startIndex, offsetBy: 19)
        let stamp = String(id[id.startIndex..<stampEnd])
        guard id[stampEnd] == "_", let startedAt = stampParser.date(from: stamp) else {
            return nil
        }
        let token = String(id[id.index(after: stampEnd)...])
        // "Zoom-Call" → "Zoom"; the generic "Call" stays "Call".
        let source = token == "Call" ? "Call"
            : (token.hasSuffix("-Call") ? String(token.dropLast(5)) : token)
        return (startedAt, source)
    }

    private static let stampParser: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
