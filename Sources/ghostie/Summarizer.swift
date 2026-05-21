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

    func summarize(transcript: String, meta: String) throws -> String {
        try provider.summarize(transcript: transcript, meta: meta)
    }
}
