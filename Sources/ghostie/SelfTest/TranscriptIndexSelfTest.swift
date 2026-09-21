import Foundation

/// Regression check for the transcript index — the layer `ghostie mcp` reads.
///
/// Everything here is pure string work over `Pipeline.render`'s output, so it
/// needs no audio, no models and no notes on disk, and is green everywhere.
///
/// The reason it is worth pinning: the index is *recovered* from markdown
/// Ghostie itself wrote. That round trip is only safe while the parser and
/// the renderer agree exactly, and they sit in different files. A change to
/// `Pipeline.render`'s line format that isn't matched here does not fail
/// loudly — it silently produces calls with zero turns, which reads as "that
/// meeting had no speech" rather than as a bug.
func runTranscriptIndexSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "\n      \(detail)")") }
    }
    print("TranscriptIndex self-test")

    // MARK: Round trip against the real renderer

    let pipeline = Pipeline(config: Config())
    let lines = [
        Pipeline.Line(startMs: 0, speaker: "Me", text: "Morning."),
        Pipeline.Line(startMs: 61_000, speaker: "Participant 1", text: "Hi — can you hear me?"),
        Pipeline.Line(startMs: 3_725_400, speaker: "Andrea", text: "That's an hour in."),
    ]
    let rendered = pipeline.render(lines)
    let parsed = TranscriptIndex.parseTurns(rendered)

    check("round trip recovers every turn", parsed.count == 3, "got \(parsed.count)")
    check("round trip keeps speakers and text",
          parsed.map(\.speaker) == ["Me", "Participant 1", "Andrea"]
              && parsed.map(\.text) == ["Morning.", "Hi — can you hear me?", "That's an hour in."],
          "\(parsed.map { "\($0.speaker)/\($0.text)" })")
    // render() truncates to whole seconds, so the recovered time is the
    // rendered one — 3_725_400 ms shows as 62:05 and comes back as 3_725_000.
    check("round trip keeps timestamps to the rendered second",
          parsed.map(\.ms) == [0, 61_000, 3_725_000], "\(parsed.map(\.ms))")

    // The bug this guards: a two-digit minute assumption drops everything
    // past the first hour of a long call, and Ghostie's calls run to two
    // hours (the 2026-09-15 Zoom call was 124 minutes).
    check("minutes past 59 are not treated as malformed",
          parsed.last?.ms == 3_725_000, "\(parsed.last?.ms ?? -1)")

    // MARK: Lines that are not turns

    let noteish = """
    # Zoom Call — Monday 21 Sep 2026 at 20:59

    - Date: Monday 21 Sep 2026 at 20:59
    - Duration: 50.1 minutes

    ---

    **[00:03] David:** Actual speech.
    """
    let fromNote = TranscriptIndex.parseTurns(noteish)
    check("meta block and headings are not parsed as turns",
          fromNote.count == 1 && fromNote[0].speaker == "David",
          "got \(fromNote.count): \(fromNote.map(\.speaker))")

    check("the no-speech placeholder yields no turns",
          TranscriptIndex.parseTurns(pipeline.render([])).isEmpty)

    // MARK: Awkward text

    // A speaker whose line opens with a colon must not have the colon eaten
    // as the label terminator.
    let colonFirst = TranscriptIndex.parseTurns("**[01:00] Me:** : and then we stopped.")
    check("text starting with a colon survives",
          colonFirst.first?.text == ": and then we stopped.",
          "got \(colonFirst.first?.text ?? "nil")")

    // Bold inside the spoken text is common once punctuation restoration has
    // run; the first `**` after the label must not truncate the turn.
    let boldInside = TranscriptIndex.parseTurns("**[02:00] Andrea:** we said **no** to that")
    check("bold inside the spoken text is kept whole",
          boldInside.first?.text == "we said **no** to that",
          "got \(boldInside.first?.text ?? "nil")")

    let wrapped = TranscriptIndex.parseTurns("""
    **[03:00] Unaku:** first half
    second half
    """)
    check("a wrapped turn keeps its words with its speaker",
          wrapped.count == 1 && wrapped.first?.text == "first half second half",
          "got \(wrapped.map(\.text))")

    // MARK: Speakers

    check("speakers are distinct and in first-spoken order",
          TranscriptIndex.speakers(in: parsed) == ["Me", "Participant 1", "Andrea"])

    // MARK: Note names

    check("a note name yields its source",
          TranscriptIndex.parseNoteName("2026-09-21_20-59-58_Zoom-Call")?.source == "Zoom")
    check("the generic note name stays \"Call\"",
          TranscriptIndex.parseNoteName("2026-09-17_15-15-12_Call")?.source == "Call")
    check("an imported note yields \"Imported\"",
          TranscriptIndex.parseNoteName("2026-09-15_09-30-23_Imported-Call")?.source == "Imported")
    check("a note name yields its start time",
          TranscriptIndex.parseNoteName("2026-09-21_20-59-58_Zoom-Call")
              .map { Calendar.current.component(.hour, from: $0.startedAt) } == 20)
    check("a foreign markdown file is not a call",
          TranscriptIndex.parseNoteName("Weekly planning") == nil)
    check("a truncated stamp is not a call",
          TranscriptIndex.parseNoteName("2026-09-21_Zoom-Call") == nil)

    // The real files that exposed this: a user's renamed copies sitting in
    // the notes folder next to the originals.
    check("a transcript is not indexed as a call",
          !TranscriptIndex.isNoteFile("2026-08-07_16-00-33_Teams-Call_transcript.md"))
    check("a renamed transcript is not indexed as a call",
          !TranscriptIndex.isNoteFile("2026-08-07_16-00-33_Teams-Call_transcript (deduplicated).md"))
    check("a note is indexed as a call",
          TranscriptIndex.isNoteFile("2026-08-07_16-00-33_Teams-Call.md"))
    check("a non-markdown file is not a call", !TranscriptIndex.isNoteFile("notes.txt"))

    check("the generic source never titles a call \"Call call\"",
          TranscriptIndex.title(for: "Call") == "Call")
    check("a named source titles a call",
          TranscriptIndex.title(for: "Zoom") == "Zoom call")

    // MARK: Meta

    check("duration is recovered from the meta block",
          TranscriptIndex.duration(fromMeta: "- Date: whenever\n- Duration: 50.1 minutes") == "50.1")
    check("a missing duration is empty, not wrong",
          TranscriptIndex.duration(fromMeta: "- Date: whenever").isEmpty)

    // MARK: Summary extraction from a whole note

    let note = """
    # Zoom Call — Monday 21 Sep 2026 at 20:59

    - Date: Monday 21 Sep 2026 at 20:59
    - Duration: 50.1 minutes

    ---

    ## Context
    We talked about pricing.

    ---

    ## Decisions
    Ship it.

    ---

    ## Full Transcript

    **[00:03] David:** Actual speech.
    """
    let summary = TranscriptIndex.summaryText(ofNoteAt: writeTemp(note))
    check("the summary stops before the transcript",
          summary?.contains("Actual speech") == false, summary ?? "nil")
    check("the summary keeps its own rules and headings",
          summary?.contains("## Decisions") == true && summary?.contains("## Context") == true,
          summary ?? "nil")

    // MARK: Round trip through the encoder

    let record = TranscriptIndex.CallRecord(
        schema: TranscriptIndex.currentSchema, id: "2026-09-21_20-59-58_Zoom-Call",
        startedAt: Date(timeIntervalSince1970: 1_790_000_000), source: "Zoom",
        durationMins: "50.1", notePath: "/tmp/note.md", transcriptPath: nil,
        speakers: ["Me"], turnCount: 1,
        turns: [TranscriptIndex.Turn(ms: 0, speaker: "Me", text: "Hello")])
    if let data = try? TranscriptIndex.makeEncoder().encode(record),
       let back = try? TranscriptIndex.makeDecoder()
        .decode(TranscriptIndex.CallRecord.self, from: data) {
        check("a record survives encode/decode",
              back.id == record.id && back.turns.first?.text == "Hello"
                  && Int(back.startedAt.timeIntervalSince1970) == 1_790_000_000)
        check("the stored date carries an offset, not a bare Z",
              !(String(data: data, encoding: .utf8) ?? "").contains("1970")
                  && (String(data: data, encoding: .utf8) ?? "").contains("startedAt"))
    } else {
        check("a record survives encode/decode", false, "coding failed")
    }

    print("TranscriptIndex: \(passed) passed, \(failed) failed")
    return failed == 0
}

/// Writes a note to a temp file for the summary-extraction checks, which read
/// by path because that is how the MCP server reads a note.
private func writeTemp(_ contents: String) -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ghostie-index-selftest-\(UUID().uuidString).md")
    try? contents.write(to: url, atomically: true, encoding: .utf8)
    return url.path
}
