import Foundation

/// The analyst prompt shared by every summarization provider. Keeping it in one
/// place means both the Claude Code path and the local Ollama path produce
/// notes with the same structure — the only thing that changes is which model
/// reads it.
enum SummarizerPrompt {
    static let system: String = """
    You are an expert meeting analyst. You receive a timestamped transcript of a \
    Microsoft Teams call captured locally. Speakers carry a real name wherever the \
    conversation established one; otherwise "Me" is the user running this tool and \
    "Participant N" (or "Participants") is everyone else on the call. Those are \
    placeholders the software wrote because nobody said the person's name, NOT \
    names, nicknames or anything the speakers would recognise — refer to such a \
    person by their role in the conversation ("the other participant", "the \
    designer") and never quote the placeholder as if it were what they are \
    called. "Me" in particular is the person who will read this note: write \
    about them in the second person ("you agreed to…", "your model"), and use \
    "You" if a table needs them in a column. Never write *Me* as though it \
    were their name. Transcription \
    and speaker labelling are automatic and may contain minor errors — infer intent \
    sensibly, treat a label as evidence rather than proof, and never invent facts \
    that are not supported by the transcript.

    Produce ONLY a clear, skimmable markdown document with EXACTLY these sections \
    (no preamble, no tool use, no questions — just the document):

    ## Context
    2-4 sentences: what this call was about and why it happened.

    ## Participants & Roles
    Bullet list of who appears to be on the call and their apparent role, based \
    only on the transcript. If unknown, say so briefly.

    ## Key Discussion Points
    Bullet list of the substantive topics, grouped logically.

    ## Decisions
    Bullet list. Each: the decision, plus rationale if stated. If none, write \
    "_No explicit decisions were made._"

    ## Action Items
    A markdown table with columns: Owner | Action | Due / Timeframe. Use the \
    speaker labels as they appear in the transcript as Owner. If none, write \
    "_No action items were identified._"

    ## Open Questions & Risks
    Bullet list of unresolved questions, blockers or risks raised.

    ## One-Paragraph Summary
    A tight executive summary (3-5 sentences).

    Start directly with "## Context".
    """

    /// Who the note is for, once naming has replaced "Me" with a real name.
    /// The system prompt's rule — "Me" is the reader — points at nobody after
    /// that, and the model has to guess from the conversation which name is
    /// the user's. On the 2026-10-16 Zoom call it guessed wrong: the other
    /// person says "thanks so much, David", and the note was written to her,
    /// with David as "co-founder or adviser". Empty when there is no one to
    /// name (an imported file, or "Me" left unnamed).
    static func readerLine(_ reader: String?) -> String {
        guard let r = reader?.trimmingCharacters(in: .whitespaces), !r.isEmpty else { return "" }
        return "\n- The reader of this note is \(r): the speaker labelled \"\(r)\" is the user running this tool (the one your instructions call \"Me\"). Write about \(r) in the second person and about everyone else in the third."
    }

    static func userContent(transcript: String, meta: String, reader: String? = nil) -> String {
        """
        Analyze the following Microsoft Teams call.

        Call metadata:
        \(meta)\(readerLine(reader))

        Transcript:
        \(transcript)
        """
    }

    // MARK: Map-reduce (transcripts beyond the provider's context budget)

    /// System prompt for one segment of an over-long call: dense notes, not
    /// a polished document — the final pass assembles the real note.
    static let segmentSystem: String = """
    You are an expert meeting analyst taking working notes. You receive ONE \
    consecutive segment of a longer timestamped Microsoft Teams call transcript. \
    Speakers carry a real name where one was established; otherwise "Me" is the \
    user running this tool and "Participant N" (or "Participants") is everyone \
    else — placeholders written by the software, never names anyone would \
    recognise. Write about "Me" in the second person ("you"), never as though \
    *Me* were their name. Transcription and speaker labelling are automatic and \
    may contain minor errors — infer intent sensibly and never invent facts.

    Produce ONLY dense markdown notes for THIS segment (no preamble):
    - Topics discussed (with who said what where it matters)
    - Decisions made (with rationale if stated)
    - Action items (owner, action, due if stated)
    - Open questions or risks raised
    Keep every timestamp reference you use in [mm:ss] form. Be complete but \
    terse — these notes feed a final summarization pass.
    """

    static func segmentUser(part: Int, of total: Int,
                            transcript: String, meta: String,
                            reader: String? = nil) -> String {
        """
        This is segment \(part) of \(total) of one Microsoft Teams call.

        Call metadata:
        \(meta)\(readerLine(reader))

        Transcript segment:
        \(transcript)
        """
    }

    /// Final pass: the normal analyst document, produced from the per-segment
    /// notes instead of the raw transcript.
    static func mergeUser(digest: String, meta: String, reader: String? = nil) -> String {
        """
        Analyze the following Microsoft Teams call. The call was too long to \
        read in one pass, so instead of the raw transcript you receive an \
        analyst's working notes for each consecutive segment, in order. Treat \
        them as one continuous call.

        Call metadata:
        \(meta)\(readerLine(reader))

        Segment notes:
        \(digest)
        """
    }

    /// Split on line boundaries into chunks of at most `budget` characters
    /// (transcripts are line-oriented: one utterance per line). A single line
    /// longer than the budget becomes its own oversized chunk rather than
    /// being cut mid-utterance.
    static func splitOnLines(_ text: String, budget: Int) -> [String] {
        guard budget > 0, text.count > budget else { return [text] }
        var chunks: [String] = []
        var current = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if !current.isEmpty && current.count + line.count + 1 > budget {
                chunks.append(current)
                current = ""
            }
            current += (current.isEmpty ? "" : "\n") + line
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
}
