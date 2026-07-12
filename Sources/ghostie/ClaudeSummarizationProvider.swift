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

    /// ~150k tokens at ~4 chars/token — comfortable inside the Claude models'
    /// 200k context with the analyst prompt and the note itself.
    var maxTranscriptChars: Int { 600_000 }

    private var timeout: TimeInterval { max(60, config.summaryTimeoutSeconds) }

    func complete(system: String, user userContent: String) throws -> String {
        let binary = claudeBinary
        guard !binary.isEmpty,
              FileManager.default.isExecutableFile(atPath: binary) else {
            throw NSError(domain: "ghostie", code: 4, userInfo: [
                NSLocalizedDescriptionKey:
                    "Claude Code CLI not found. Install it and run `claude` once to log in, or set claudeBinary in Settings."
            ])
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = [
            "-p",
            "--output-format", "text",
            "--model", config.summaryModel,
            // Replace Claude Code's agentic system prompt with our analyst one.
            "--system-prompt", system
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

        // All pipe I/O happens on background queues so the only thing this
        // thread ever blocks on is the watchdog below. Inline reads/writes
        // would re-introduce two hangs: a CLI that never reads stdin stalls
        // the write (transcripts exceed the 64 KB pipe buffer), and a CLI
        // that holds stdout open (auth prompt, network hang) stalls
        // `readDataToEndOfFile()` forever — wedging the serial work queue
        // with the app stuck on "Summarizing call…" for its lifetime.
        let io = DispatchQueue(label: "ghostie.claude.io", attributes: .concurrent)

        // Feed the transcript on stdin, then close it. F_SETNOSIGPIPE so a
        // CLI killed by the watchdog mid-write surfaces as EPIPE (a thrown
        // error we discard) instead of a process-killing SIGPIPE.
        let stdinHandle = stdinPipe.fileHandleForWriting
        _ = fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1)
        io.async {
            if let data = userContent.data(using: .utf8) {
                try? stdinHandle.write(contentsOf: data)
            }
            try? stdinHandle.close()
        }

        // Drain stdout and stderr concurrently while the process runs, so
        // >64 KB of early stderr can't wedge both processes against a full
        // pipe buffer. Each stream signals once at EOF.
        var outData = Data()
        var errData = Data()
        let drained = DispatchSemaphore(value: 0)
        io.async { outData = outPipe.fileHandleForReading.readDataToEndOfFile(); drained.signal() }
        io.async { errData = errPipe.fileHandleForReading.readDataToEndOfFile(); drained.signal() }

        // Watchdog: the cap (config.summaryTimeoutSeconds) covers the
        // *running* process, not just the post-EOF wait. On timeout: SIGTERM,
        // brief grace, SIGKILL — mirroring the whisper-server teardown in
        // `LanguageIdentifier`.
        let deadline = DispatchTime.now() + timeout
        let waiter = DispatchQueue(label: "ghostie.claude.wait")
        let exited = DispatchSemaphore(value: 0)
        waiter.async { proc.waitUntilExit(); exited.signal() }
        if exited.wait(timeout: deadline) == .timedOut {
            proc.terminate()                                   // SIGTERM
            if exited.wait(timeout: .now() + 2) == .timedOut {
                kill(proc.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
            // Death closes the CLI's pipe ends so the drains unblock; the
            // waits are bounded in case a stray child inherited the fds.
            _ = drained.wait(timeout: .now() + 2)
            _ = drained.wait(timeout: .now() + 2)
            throw NSError(domain: "ghostie", code: 6, userInfo: [
                NSLocalizedDescriptionKey:
                    "claude produced no result within \(Int(timeout)) s and was terminated — it may have been waiting on login or the network. Run `claude` once interactively to check, or raise summaryTimeoutSeconds."
            ])
        }

        // Exited in time; both drains finish at EOF moments later. Bounded by
        // the same budget so an inherited fd held open by a stray child can't
        // re-introduce the forever-hang.
        if drained.wait(timeout: deadline) == .timedOut
            || drained.wait(timeout: deadline) == .timedOut {
            throw NSError(domain: "ghostie", code: 6, userInfo: [
                NSLocalizedDescriptionKey:
                    "claude exited but its output streams never closed within \(Int(timeout)) s."
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
