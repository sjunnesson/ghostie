import Foundation

/// The analyst prompt shared by every summarization provider. Keeping it in one
/// place means both the Claude Code path and the local Ollama path produce
/// notes with the same structure — the only thing that changes is which model
/// reads it.
enum SummarizerPrompt {
    static let system: String = """
    You are an expert meeting analyst. You receive a timestamped transcript of a \
    Microsoft Teams call captured locally. Speaker "Me" is the user running this \
    tool; "Participants" is everyone else on the call. Transcription is automatic \
    and may contain minor errors — infer intent sensibly and never invent facts \
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
    A markdown table with columns: Owner | Action | Due / Timeframe. Use "Me" or \
    a named participant as Owner. If none, write "_No action items were identified._"

    ## Open Questions & Risks
    Bullet list of unresolved questions, blockers or risks raised.

    ## One-Paragraph Summary
    A tight executive summary (3-5 sentences).

    Start directly with "## Context".
    """

    static func userContent(transcript: String, meta: String) -> String {
        """
        Analyze the following Microsoft Teams call.

        Call metadata:
        \(meta)

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
    Speaker "Me" is the user running this tool; "Participants" is everyone else. \
    Transcription is automatic and may contain minor errors — infer intent \
    sensibly and never invent facts.

    Produce ONLY dense markdown notes for THIS segment (no preamble):
    - Topics discussed (with who said what where it matters)
    - Decisions made (with rationale if stated)
    - Action items (owner, action, due if stated)
    - Open questions or risks raised
    Keep every timestamp reference you use in [mm:ss] form. Be complete but \
    terse — these notes feed a final summarization pass.
    """

    static func segmentUser(part: Int, of total: Int,
                            transcript: String, meta: String) -> String {
        """
        This is segment \(part) of \(total) of one Microsoft Teams call.

        Call metadata:
        \(meta)

        Transcript segment:
        \(transcript)
        """
    }

    /// Final pass: the normal analyst document, produced from the per-segment
    /// notes instead of the raw transcript.
    static func mergeUser(digest: String, meta: String) -> String {
        """
        Analyze the following Microsoft Teams call. The call was too long to \
        read in one pass, so instead of the raw transcript you receive an \
        analyst's working notes for each consecutive segment, in order. Treat \
        them as one continuous call.

        Call metadata:
        \(meta)

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
