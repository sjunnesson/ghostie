import Foundation

/// Façade over the configured `SummarizationProvider`. Keeps the call sites in
/// `Pipeline.swift` (`Summarizer(config:).isConfigured`, `.summarize(...)`)
/// stable regardless of which backend the user has chosen in Settings.
struct Summarizer {
    let config: Config

    var provider: SummarizationProvider {
        switch config.summaryProvider {
        case "ollama":
            return OllamaSummarizationProvider(config: config)
        default:
            return ClaudeSummarizationProvider(config: config)
        }
    }

    var isConfigured: Bool { provider.isConfigured }

    /// Single-shot when the transcript fits the provider's context budget;
    /// otherwise two-level map-reduce: per-segment working notes, then the
    /// normal analyst document over the notes. A multi-hour call used to
    /// blow the model's context window and fail the whole summary.
    func summarize(transcript: String, meta: String) throws -> String {
        let p = provider
        guard transcript.count > p.maxTranscriptChars else {
            return try p.summarize(transcript: transcript, meta: meta)
        }
        let chunks = SummarizerPrompt.splitOnLines(transcript, budget: p.maxTranscriptChars)
        Log.warn("Transcript is \(transcript.count) chars — over the \(config.summaryProvider) provider's \(p.maxTranscriptChars)-char budget; summarizing in \(chunks.count) segments.")
        var notes: [String] = []
        for (i, chunk) in chunks.enumerated() {
            Log.info("Summarizing segment \(i + 1)/\(chunks.count)…")
            let n = try p.complete(
                system: SummarizerPrompt.segmentSystem,
                user: SummarizerPrompt.segmentUser(part: i + 1, of: chunks.count,
                                                   transcript: chunk, meta: meta))
            notes.append("### Segment \(i + 1) of \(chunks.count)\n\(n)")
        }
        return try p.complete(
            system: SummarizerPrompt.system,
            user: SummarizerPrompt.mergeUser(digest: notes.joined(separator: "\n\n"),
                                             meta: meta))
    }
}
