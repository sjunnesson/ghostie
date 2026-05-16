import Foundation

/// Sends the merged transcript to the Anthropic Messages API and asks for a
/// structured markdown analysis (context, decisions, actions).
struct Summarizer {
    let config: Config

    var isConfigured: Bool { !config.anthropicApiKey.isEmpty }

    private static let systemPrompt = """
    You are an expert meeting analyst. You receive a timestamped transcript of a \
    Microsoft Teams call captured locally. Speaker "Me" is the user running this \
    tool; "Participants" is everyone else on the call. Transcription is automatic \
    and may contain minor errors — infer intent sensibly and never invent facts \
    that are not supported by the transcript.

    Produce a clear, skimmable markdown document with EXACTLY these sections:

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

    Do not add a top-level title or any preamble — start directly with "## Context".
    """

    func summarize(transcript: String, meta: String) throws -> String {
        guard isConfigured else {
            throw NSError(domain: "ghostie", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "No Anthropic API key configured."
            ])
        }

        let userContent = """
        Call metadata:
        \(meta)

        Transcript:
        \(transcript)
        """

        let body: [String: Any] = [
            "model": config.summaryModel,
            "max_tokens": 4096,
            "system": Self.systemPrompt,
            "messages": [
                ["role": "user", "content": userContent]
            ]
        ]

        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.anthropicApiKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 180

        let sem = DispatchSemaphore(value: 0)
        var resultText: String?
        var failure: String?

        let task = URLSession.shared.dataTask(with: req) { data, response, error in
            defer { sem.signal() }
            if let error { failure = error.localizedDescription; return }
            guard let data else { failure = "No response data."; return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { failure = "Unparseable response (HTTP \(code))."; return }
            if code != 200 {
                let err = (json["error"] as? [String: Any])?["message"] as? String
                failure = "Anthropic API HTTP \(code): \(err ?? String(data: data, encoding: .utf8) ?? "unknown")"
                return
            }
            if let content = json["content"] as? [[String: Any]],
               let first = content.first, let text = first["text"] as? String {
                resultText = text
            } else {
                failure = "Unexpected response shape."
            }
        }
        task.resume()
        sem.wait()

        if let resultText { return resultText }
        throw NSError(domain: "ghostie", code: 5, userInfo: [
            NSLocalizedDescriptionKey: failure ?? "Unknown summarization error."
        ])
    }
}
