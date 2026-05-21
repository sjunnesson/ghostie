import Foundation

/// Talks to a local (or LAN) Ollama server over HTTP. No shell-out, no CLI
/// dependency — just `URLSession`. With this provider selected, the transcript
/// never leaves the machine running Ollama, so a privacy-strict user can run
/// Ghostie end-to-end locally.
struct OllamaSummarizationProvider: SummarizationProvider {
    let config: Config

    /// Five-minute wall-clock cap on summarization, matching the Claude path.
    /// Long-context local models on slower hardware can take several minutes,
    /// so this is deliberately generous.
    private static let summarizeTimeout: TimeInterval = 300

    /// Short timeout for the `/api/tags` health check — we'd rather show
    /// "Not reachable" promptly than block the Settings UI for ten seconds
    /// while waiting on a dead localhost.
    private static let probeTimeout: TimeInterval = 2

    var isConfigured: Bool {
        // A configured provider needs (a) a reachable server with at least
        // one pulled model, AND (b) the configured `ollamaModel` to be one
        // of those. An empty `ollamaModel` (default) is treated as unconfigured
        // so a brand-new user is nudged into Settings instead of silently
        // hitting a 404 mid-call.
        guard !config.ollamaModel.isEmpty else { return false }
        let models = Self.listInstalledModels(url: config.ollamaUrl)
        return models.contains(config.ollamaModel)
    }

    var displayStatus: String {
        if config.ollamaModel.isEmpty { return "Pick a model" }
        let models = Self.listInstalledModels(url: config.ollamaUrl)
        if models.isEmpty { return "Not reachable" }
        return models.contains(config.ollamaModel) ? "Ready" : "Model not pulled"
    }

    func summarize(transcript: String, meta: String) throws -> String {
        guard !config.ollamaModel.isEmpty else {
            throw NSError(domain: "ghostie", code: 10, userInfo: [
                NSLocalizedDescriptionKey:
                    "No Ollama model selected. Open Settings → Summary and pick one (e.g. `llama3.1:8b`)."
            ])
        }

        guard let baseURL = Self.normalizedBaseURL(config.ollamaUrl) else {
            throw NSError(domain: "ghostie", code: 11, userInfo: [
                NSLocalizedDescriptionKey:
                    "Ollama URL `\(config.ollamaUrl)` is not a valid URL."
            ])
        }

        let userContent = SummarizerPrompt.userContent(transcript: transcript, meta: meta)
        let body: [String: Any] = [
            "model": config.ollamaModel,
            "messages": [
                ["role": "system", "content": SummarizerPrompt.system],
                ["role": "user",   "content": userContent]
            ],
            "stream": false,
            "options": ["temperature": 0.2]
        ]
        let payload: Data
        do {
            payload = try JSONSerialization.data(withJSONObject: body)
        } catch {
            throw NSError(domain: "ghostie", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Could not serialize Ollama request: \(error.localizedDescription)"
            ])
        }

        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = payload
        req.timeoutInterval = Self.summarizeTimeout

        Log.info("Summarizing via Ollama (\(config.ollamaModel) at \(baseURL.absoluteString))…")

        let result = Self.syncDataTask(request: req, timeout: Self.summarizeTimeout)
        switch result {
        case .failure(let err):
            throw NSError(domain: "ghostie", code: 13, userInfo: [
                NSLocalizedDescriptionKey:
                    "Ollama request failed: \(err.localizedDescription). Is `ollama serve` running at \(baseURL.absoluteString)?"
            ])
        case .success(let (data, http)):
            guard (200..<300).contains(http.statusCode) else {
                let snippet = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                throw NSError(domain: "ghostie", code: 14, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Ollama returned \(http.statusCode). \(snippet.isEmpty ? "Check the model name and server URL." : snippet)"
                ])
            }
            guard
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let message = json["message"] as? [String: Any],
                let content = (message["content"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !content.isEmpty
            else {
                throw NSError(domain: "ghostie", code: 15, userInfo: [
                    NSLocalizedDescriptionKey:
                        "Ollama response did not include a summary. Try a different model or check `ollama logs`."
                ])
            }
            return content
        }
    }

    // MARK: - /api/tags

    /// List of installed model names (e.g. `["llama3.1:8b", "qwen2.5:14b"]`).
    /// Empty when the server is unreachable — the caller treats that as
    /// "not reachable", not as "no models installed", so an unreachable host
    /// never silently masquerades as a working one.
    static func listInstalledModels(url: String) -> [String] {
        guard let base = normalizedBaseURL(url) else { return [] }
        var req = URLRequest(url: base.appendingPathComponent("api/tags"))
        req.httpMethod = "GET"
        req.timeoutInterval = probeTimeout
        let result = syncDataTask(request: req, timeout: probeTimeout)
        guard case .success(let (data, http)) = result,
              (200..<300).contains(http.statusCode),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else {
            return []
        }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    // MARK: - Helpers

    private static func normalizedBaseURL(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        if !s.contains("://") { s = "http://" + s }
        // Strip a trailing slash so `appendingPathComponent("api/...")` yields
        // a clean URL regardless of how the user typed the base.
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s)
    }

    /// `URLSession.dataTask` wrapped in a semaphore so the call site stays
    /// synchronous. The pipeline runs on a `DispatchQueue.work` thread (not
    /// the main queue), so blocking here is safe.
    private static func syncDataTask(
        request: URLRequest,
        timeout: TimeInterval
    ) -> Result<(Data, HTTPURLResponse), Error> {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)
        let sem = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error> =
            .failure(NSError(domain: "ghostie", code: 99,
                             userInfo: [NSLocalizedDescriptionKey: "no response"]))
        let task = session.dataTask(with: request) { data, response, error in
            if let error {
                result = .failure(error)
            } else if let http = response as? HTTPURLResponse {
                result = .success((data ?? Data(), http))
            } else {
                result = .failure(NSError(domain: "ghostie", code: 98, userInfo: [
                    NSLocalizedDescriptionKey: "Unexpected response from Ollama."
                ]))
            }
            sem.signal()
        }
        task.resume()
        // Wait a bit beyond the per-request timeout so URLSession can fire its
        // own timeout error instead of us racing it.
        _ = sem.wait(timeout: .now() + timeout + 5)
        session.finishTasksAndInvalidate()
        return result
    }
}
