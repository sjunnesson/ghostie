import Foundation

/// Shells out to the Claude Code CLI (`claude -p`) using the user's existing
/// Claude Code login — no Anthropic API key required. The system prompt is
/// swapped for `SummarizerPrompt.system` and cwd is `NSTemporaryDirectory()`
/// so no unrelated project `CLAUDE.md` leaks into the note.
struct ClaudeSummarizationProvider: SummarizationProvider {
    let config: Config

    /// Resolved path to the `claude` binary ("" if not found).
    var claudeBinary: String {
        config.claudeBinary.isEmpty ? Config.findClaudeBinary() : config.claudeBinary
    }

    var isConfigured: Bool {
        let b = claudeBinary
        return !b.isEmpty && FileManager.default.isExecutableFile(atPath: b)
    }

    var displayStatus: String {
        isConfigured ? "Signed in" : "Missing"
    }

    func summarize(transcript: String, meta: String) throws -> String {
        let binary = claudeBinary
        guard !binary.isEmpty,
              FileManager.default.isExecutableFile(atPath: binary) else {
            throw NSError(domain: "ghostie", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                    "Claude Code CLI not found. Install it and run `claude` once to log in, or set claudeBinary in Settings."
            ])
        }

        let userContent = SummarizerPrompt.userContent(transcript: transcript, meta: meta)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "-p",
            "--output-format", "text",
            "--model", config.summaryModel,
            // Replace Claude Code's agentic system prompt with our analyst one.
            "--system-prompt", SummarizerPrompt.system
        ]
        // Neutral cwd so no unrelated project CLAUDE.md is picked up.
        proc.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())

        let stdinPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardInput = stdinPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        Log.info("Summarizing via `claude -p` (\(config.summaryModel))…")
        do {
            try proc.run()
        } catch {
            throw NSError(domain: "ghostie", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Could not launch claude: \(error.localizedDescription)"
            ])
        }

        // Feed the transcript on stdin, then close it.
        if let data = userContent.data(using: .utf8) {
            stdinPipe.fileHandleForWriting.write(data)
        }
        try? stdinPipe.fileHandleForWriting.close()

        // Read fully before waiting (avoids pipe-buffer deadlock on long output).
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()

        // Watchdog: don't hang forever if the CLI stalls.
        let deadline = DispatchTime.now() + 300
        let waiter = DispatchQueue(label: "ghostie.claude.wait")
        let sem = DispatchSemaphore(value: 0)
        waiter.async { proc.waitUntilExit(); sem.signal() }
        if sem.wait(timeout: deadline) == .timedOut {
            proc.terminate()
            throw NSError(domain: "ghostie", code: 6, userInfo: [
                NSLocalizedDescriptionKey: "claude timed out after 5 minutes."
            ])
        }

        let out = String(data: outData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard proc.terminationStatus == 0, !out.isEmpty else {
            let err = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw NSError(domain: "ghostie", code: 7, userInfo: [
                NSLocalizedDescriptionKey:
                    "claude exited \(proc.terminationStatus). \(err.isEmpty ? "Are you logged in? Run `claude` once interactively." : err)"
            ])
        }
        return out
    }
}
