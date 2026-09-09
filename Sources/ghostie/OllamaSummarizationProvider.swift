import Foundation

/// Talks to a local (or LAN) Ollama server over HTTP. No shell-out, no CLI
/// dependency — just `URLSession`. With this provider selected, the transcript
/// never leaves the machine running Ollama, so a privacy-strict user can run
/// Ghostie end-to-end locally.
struct OllamaSummarizationProvider: SummarizationProvider {
    let config: Config

    /// Wall-clock cap on one summarization request (config-driven, default
    /// 300 s, min 60). Long-context local models on slower hardware can take
    /// several minutes, so the default is deliberately generous.
    private var summarizeTimeout: TimeInterval { max(60, config.summaryTimeoutSeconds) }

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

    /// Local models commonly run 8k-token contexts (Ollama's default window
    /// is smaller still); ~6k tokens of transcript leaves room for the
    /// analyst prompt and the note. Long calls go through the map-reduce
    /// path in `Summarizer` rather than silently overflowing the window.
    var maxTranscriptChars: Int { 24_000 }

    /// The `/api/chat` request body.
    ///
    /// `think: false` matters more than it looks. Every current small model
    /// worth running locally for this — the Qwen3 family especially — reasons
    /// before answering unless told not to, and the two jobs sent here are
    /// exactly the ones where that is pure waste: restoring punctuation and
    /// writing a note from a transcript that is already in front of it. Left
    /// on, a 4B model spends its speed advantage thinking, and the reasoning
    /// it emits can push the reply out of the shape `TranscriptRefiner.parse`
    /// requires, costing the batch its punctuation as well as the time.
    ///
    /// Models with no thinking mode reject the field outright, which is why
    /// `complete` retries once without it rather than assuming either way.
    /// Static + pure so `selftest` can check the shape without a server.
    static func requestBody(model: String, system: String, user: String,
                            think: Bool?) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user",   "content": user]
            ],
            "stream": false,
            "options": ["temperature": 0.2]
        ]
        if let think { body["think"] = think }
        return body
    }

    /// Whether an Ollama error body is complaining about `think` rather than
    /// about the request itself.
    static func mentionsThinking(_ data: Data) -> Bool {
        guard let s = String(data: data, encoding: .utf8)?.lowercased() else { return false }
        return s.contains("think")
    }

    func complete(system: String, user userContent: String,
                  purpose: String = "Summarizing") throws -> String {
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

        let payload: Data
        do {
            payload = try JSONSerialization.data(
                withJSONObject: Self.requestBody(model: config.ollamaModel,
                                                 system: system, user: userContent,
                                                 think: false))
        } catch {
            throw NSError(domain: "ghostie", code: 12, userInfo: [
                NSLocalizedDescriptionKey: "Could not serialize Ollama request: \(error.localizedDescription)"
            ])
        }

        func request(_ body: Data) -> URLRequest {
            var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
            req.timeoutInterval = summarizeTimeout
            return req
        }

        Log.info("\(purpose) via Ollama (\(config.ollamaModel) at \(baseURL.absoluteString))…")

        var result = Self.syncDataTask(request: request(payload), timeout: summarizeTimeout)
        // A model with no thinking mode rejects the field rather than
        // ignoring it. Ask again without it before giving up — the point of
        // sending it is speed, never a requirement.
        if case .success(let (data, http)) = result, http.statusCode == 400,
           Self.mentionsThinking(data),
           let plain = try? JSONSerialization.data(
                withJSONObject: Self.requestBody(model: config.ollamaModel,
                                                 system: system, user: userContent,
                                                 think: nil)) {
            result = Self.syncDataTask(request: request(plain), timeout: summarizeTimeout)
        }
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
