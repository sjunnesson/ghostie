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
    /// `purpose` names the stage this request belongs to, for the log — the
    /// same provider serves the summary, punctuation restoration and speaker
    /// naming, and a run of identical "summarizing…" lines during a
    /// punctuation pass is a log that misreports what the machine is doing.
    func complete(system: String, user: String, purpose: String) throws -> String
}

extension SummarizationProvider {
    func complete(system: String, user: String) throws -> String {
        try complete(system: system, user: user, purpose: "Summarizing")
    }

    /// Single-shot analyst summary; `Summarizer` calls this when the
    /// transcript fits `maxTranscriptChars`.
    func summarize(transcript: String, meta: String, reader: String? = nil) throws -> String {
        try complete(system: SummarizerPrompt.system,
                     user: SummarizerPrompt.userContent(transcript: transcript, meta: meta,
                                                        reader: reader))
    }
}

/// The provider answered, and the answer was "not now": the user's own usage
/// allowance is spent. Nothing is wrong with the request or the transcript, so
/// this is not a failure to count against a call. Every further request until
/// the reset is refused the same way, which makes "try the next batch" waste.
///
/// On 2026-10-16 a 105-minute call hit a session limit after recording. Seven
/// punctuation batches were each sent twice, naming once, the summary twice,
/// and all were refused. The note kept whisper's run-on text and
/// "Participant 1" for good, because only the summary was ever retried.
struct ProviderLimitReached: LocalizedError {
    /// The provider's own words, e.g. "You've hit your session limit ·
    /// resets 7:10pm (Europe/Stockholm)".
    let message: String

    var errorDescription: String? { message }

    /// When the provider said the limit lifts, as it said it ("7:10pm
    /// (Europe/Stockholm)"). Shown to the user, never parsed into a date:
    /// the CLI's wording is not a contract, and the backlog retries on its
    /// own timer regardless.
    var resetsAt: String? {
        guard let r = message.range(of: #"resets\s+(at\s+)?"#, options: [.regularExpression, .caseInsensitive])
        else { return nil }
        let rest = message[r.upperBound...]
            .prefix { $0 != "\n" && $0 != "·" && $0 != "|" }
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: ".")))
        return rest.isEmpty ? nil : rest
    }

    /// A usage limit in a provider's reply. Deliberately narrow: "limit" alone
    /// also appears in context-length and timeout errors, which are real
    /// failures and must keep counting.
    static func detect(_ text: String) -> ProviderLimitReached? {
        let patterns = [
            #"hit your (session |usage |weekly |daily |monthly )?limit"#,
            #"(session|usage|weekly|daily|monthly|5-hour) limit (reached|exceeded)"#,
            #"usage limit"#,
            #"out of (extra )?usage"#,
        ]
        func matches(_ s: some StringProtocol) -> Bool {
            patterns.contains { s.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
        }
        guard matches(text) else { return nil }
        let line = text.split(separator: "\n").first { matches($0) }
        return ProviderLimitReached(
            message: String(line ?? Substring(text)).trimmingCharacters(in: .whitespaces))
    }
}
