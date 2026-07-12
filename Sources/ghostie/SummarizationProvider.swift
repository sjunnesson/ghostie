import Foundation

/// One backend that can turn a transcript into the analyst markdown document.
/// Today there are two: the Claude Code CLI (cloud) and Ollama (fully local).
/// The chosen provider is honored strictly — no silent fallback to the other —
/// so a privacy-strict user who picks Ollama never sees a transcript leave the
/// machine.
protocol SummarizationProvider {
    /// Whether this provider is ready to summarize right now. A `false` here
    /// causes `Pipeline` to write the note with a "Summary queued" banner and
    /// drop the transcript into the backlog for later retry.
    var isConfigured: Bool { get }

    /// One-line human-readable status for the Settings UI, e.g.
    /// "Signed in", "Not reachable", "Pick a model".
    var displayStatus: String { get }

    /// The largest transcript (in characters) one request can safely carry
    /// without blowing the model's context window. Transcripts beyond this
    /// are summarized in parts by `Summarizer` (map-reduce) instead of
    /// failing the whole call.
    var maxTranscriptChars: Int { get }

    /// One completion round-trip with an arbitrary system prompt — the
    /// primitive that both the single-shot summary and the chunked
    /// map-reduce path build on. Blocks until a result is produced or
    /// throws. Errors should use the `"ghostie"` `NSError` domain so the
    /// existing Pipeline + Backlog error handling treats every provider's
    /// failures identically.
    func complete(system: String, user: String) throws -> String
}

extension SummarizationProvider {
    /// Single-shot analyst summary; `Summarizer` calls this when the
    /// transcript fits `maxTranscriptChars`.
    func summarize(transcript: String, meta: String) throws -> String {
        try complete(system: SummarizerPrompt.system,
                     user: SummarizerPrompt.userContent(transcript: transcript, meta: meta))
    }
}
