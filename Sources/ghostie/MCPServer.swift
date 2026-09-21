import Foundation
import MCP

/// `ghostie mcp` — an MCP server over stdio, so any assistant that speaks the
/// protocol can read the calls Ghostie has already transcribed. Claude
/// Desktop and Claude Code, Cursor, VS Code, Windsurf, LM Studio pointed at a
/// local model, or anything else that can launch a stdio server: the protocol
/// is the contract, and nothing in here knows or cares which client is
/// asking.
///
/// Read-only by design. Every tool here answers a question about notes that
/// are already on disk; nothing starts a recording, changes a setting or
/// deletes anything. That is not a limitation to be fixed later so much as
/// the shape of the promise: registering this server lets an assistant read
/// your meetings, and nothing else.
///
/// **Everything here is sized for a context window, not for a disk.** A
/// 50-minute call is a 60 kB transcript; a handful of them handed over
/// unasked is the whole conversation budget spent before the model has done
/// any thinking — and a small local model may have only a few thousand tokens
/// to spend. So every tool is bounded by default — listings carry
/// metadata and no turns, `get_call` returns the written summary and not the
/// transcript, and the transcript itself is paginated and filterable. The
/// model asks for more when it needs more.
///
/// Answers are markdown text, not duplicated into `structuredContent`. For a
/// server whose payload *is* prose, emitting every answer twice would halve
/// the usable context to restate what the text already says.
enum GhostieMCPServer {

    static let serverName = "ghostie"

    /// Turns per page from `ghostie_get_transcript`. Roughly ten minutes of a
    /// normal conversation — enough to answer "what did they say about X"
    /// without committing the whole call.
    static let defaultTurnLimit = 150
    static let maxTurnLimit = 1000

    static let defaultCallLimit = 20
    static let maxCallLimit = 200

    // MARK: Entry point

    /// Runs until the client disconnects (Claude closes the pipe).
    ///
    /// Blocking rather than `async` because `main.swift` dispatches
    /// synchronously and the MCP process has nothing else to do: the main
    /// thread parks on the semaphore while the server runs on the cooperative
    /// pool.
    static func runBlocking(config: Config) {
        let done = DispatchSemaphore(value: 0)
        Task {
            do {
                try await run(config: config)
            } catch {
                Log.error("MCP server stopped: \(error.localizedDescription)")
            }
            done.signal()
        }
        done.wait()
    }

    private static func run(config: Config) async throws {
        // A first run has notes but no index — the notes predate this
        // feature. Rebuilding here rather than telling the user to go and run
        // `ghostie index` is the difference between the server working the
        // moment it is connected and the user's first question returning an
        // instruction. It costs one pass over the notes folder, and only when
        // the index is genuinely empty.
        if TranscriptIndex.summaries().isEmpty {
            let result = TranscriptIndex.rebuild(notesFolder: config.notesFolder)
            if result.indexed > 0 {
                Log.info("MCP: indexed \(result.indexed) existing notes on first run")
            }
        }

        let server = Server(
            name: serverName,
            version: Updater.runningVersion().raw,
            instructions: """
                Ghostie records the user's Teams, Zoom and Google Meet calls \
                locally and writes a summary note plus a speaker-labelled \
                transcript for each one.

                Start from ghostie_get_latest_call (the most recent call) or \
                ghostie_list_calls (to find an older one), then use \
                ghostie_get_transcript for what was actually said. Every tool \
                that takes an `id` also accepts "latest".

                Transcripts are long. Prefer ghostie_search_calls to locate a \
                passage and ghostie_get_transcript with a time range or \
                speaker filter to read around it, rather than fetching a whole \
                call.

                Speaker labels come from the recording: "Me" is the user, and \
                other speakers are named when Ghostie could establish a name \
                and numbered ("Participant 2") when it could not.
                """,
            capabilities: .init(
                prompts: .init(listChanged: false),
                resources: .init(subscribe: false, listChanged: false),
                tools: .init(listChanged: false)))

        await registerTools(on: server, config: config)
        await registerResources(on: server, config: config)
        await registerPrompts(on: server)

        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }

    // MARK: Tools

    private static func registerTools(on server: Server, config: Config) async {
        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: toolDefinitions)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                let text: String
                switch params.name {
                case "ghostie_get_latest_call":
                    text = try getLatestCall(params.arguments)
                case "ghostie_list_calls":
                    text = try listCalls(params.arguments)
                case "ghostie_get_call":
                    text = try getCall(params.arguments)
                case "ghostie_get_transcript":
                    text = try getTranscript(params.arguments)
                case "ghostie_search_calls":
                    text = try searchCalls(params.arguments)
                case "ghostie_get_status":
                    text = getStatus(config)
                default:
                    return .init(content: [.text(text: "Unknown tool: \(params.name)", annotations: nil, _meta: nil)],
                                 isError: true)
                }
                return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
            } catch let error as ToolError {
                // Tool-level errors come back as content with isError, not as
                // protocol errors: the model should read "no call matches that
                // id, here are the ids that exist" and try again, which a
                // JSON-RPC error would deny it.
                return .init(content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
            } catch {
                return .init(content: [.text(text: "Ghostie failed to answer: \(error.localizedDescription)", annotations: nil, _meta: nil)],
                             isError: true)
            }
        }
    }

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false,
        idempotentHint: true, openWorldHint: false)

    private static var toolDefinitions: [Tool] {
        [
            Tool(
                name: "ghostie_get_latest_call",
                description: """
                    The user's most recent recorded call: when it happened, how \
                    long it ran, who spoke, and the written summary. Start here \
                    for "my last call" / "the meeting I just had". Returns the \
                    summary only — call ghostie_get_transcript with the returned \
                    id for what was actually said.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object([
                            "type": .string("string"),
                            "description": .string(
                                "Only consider calls from this app: Zoom, Teams, Meet, Imported. Omit for the latest call of any kind."),
                        ])
                    ]),
                ]),
                annotations: readOnly),

            Tool(
                name: "ghostie_list_calls",
                description: """
                    List recorded calls, newest first, with id, date, duration \
                    and speakers. No transcript content — this is the index you \
                    pick an id from. Use it to find a call by when it happened \
                    or who was on it; use ghostie_search_calls to find one by \
                    what was said.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("How many calls to return (default \(defaultCallLimit), max \(maxCallLimit))."),
                        ]),
                        "offset": .object([
                            "type": .string("integer"),
                            "description": .string("Skip this many calls first, for paging through older ones."),
                        ]),
                        "since": .object([
                            "type": .string("string"),
                            "description": .string("Only calls on or after this date, as YYYY-MM-DD."),
                        ]),
                        "until": .object([
                            "type": .string("string"),
                            "description": .string("Only calls on or before this date, as YYYY-MM-DD."),
                        ]),
                        "speaker": .object([
                            "type": .string("string"),
                            "description": .string("Only calls where this speaker label appears, matched case-insensitively on part of the name."),
                        ]),
                        "source": .object([
                            "type": .string("string"),
                            "description": .string("Only calls from this app: Zoom, Teams, Meet, Imported."),
                        ]),
                    ]),
                ]),
                annotations: readOnly),

            Tool(
                name: "ghostie_get_call",
                description: """
                    One call's metadata and written summary, by id. Does not \
                    include the transcript — use ghostie_get_transcript for that.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Call id from ghostie_list_calls, e.g. 2026-09-21_20-59-58_Zoom-Call. \"latest\" is accepted."),
                        ])
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: readOnly),

            Tool(
                name: "ghostie_get_transcript",
                description: """
                    What was said on a call, as timestamped speaker turns. \
                    Paginated: returns \(defaultTurnLimit) turns by default and \
                    tells you the offset to continue from. Narrow with \
                    from_time/to_time or speaker rather than paging through a \
                    long call — a full hour-long transcript is tens of \
                    thousands of tokens.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Call id, or \"latest\" for the most recent call."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Turns to return (default \(defaultTurnLimit), max \(maxTurnLimit))."),
                        ]),
                        "offset": .object([
                            "type": .string("integer"),
                            "description": .string("Skip this many turns first. Use the next_offset from the previous page."),
                        ]),
                        "from_time": .object([
                            "type": .string("string"),
                            "description": .string("Only turns at or after this point in the call, as MM:SS or HH:MM:SS."),
                        ]),
                        "to_time": .object([
                            "type": .string("string"),
                            "description": .string("Only turns at or before this point in the call, as MM:SS or HH:MM:SS."),
                        ]),
                        "speaker": .object([
                            "type": .string("string"),
                            "description": .string("Only turns by this speaker, matched case-insensitively on part of the label."),
                        ]),
                    ]),
                    "required": .array([.string("id")]),
                ]),
                annotations: readOnly),

            Tool(
                name: "ghostie_search_calls",
                description: """
                    Find where something was said across every recorded call. \
                    Returns matching turns with their call id and timestamp, \
                    never whole transcripts — read around a hit with \
                    ghostie_get_transcript using its time and id. \
                    Case-insensitive substring match.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Text to look for in what people said."),
                        ]),
                        "id": .object([
                            "type": .string("string"),
                            "description": .string("Search only within this call. Omit to search all of them."),
                        ]),
                        "speaker": .object([
                            "type": .string("string"),
                            "description": .string("Only turns by this speaker."),
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum matching turns to return (default 25, max 100)."),
                        ]),
                    ]),
                    "required": .array([.string("query")]),
                ]),
                annotations: readOnly),

            Tool(
                name: "ghostie_get_status",
                description: """
                    Whether Ghostie is set up and working: how many calls are \
                    indexed, where notes are written, whether anything is stuck \
                    in the retry backlog, and which transcription models are \
                    installed. Use when a call the user expects is missing.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:]),
                ]),
                annotations: readOnly),
        ]
    }

    // MARK: Tool implementations

    struct ToolError: Error {
        let message: String
    }

    private static func getLatestCall(_ args: [String: Value]?) throws -> String {
        var calls = TranscriptIndex.summaries()
        if let source = args?["source"]?.stringValue, !source.isEmpty {
            calls = calls.filter { $0.source.caseInsensitiveCompare(source) == .orderedSame }
            guard let latest = calls.first else {
                throw ToolError(message: "No \(source) calls have been recorded. "
                    + "Call ghostie_list_calls with no source to see what is there.")
            }
            return renderCall(latest)
        }
        guard let latest = calls.first else { throw noCallsError() }
        return renderCall(latest)
    }

    private static func listCalls(_ args: [String: Value]?) throws -> String {
        var calls = TranscriptIndex.summaries()
        guard !calls.isEmpty else { throw noCallsError() }

        if let since = args?["since"]?.stringValue, let date = parseDay(since) {
            calls = calls.filter { $0.startedAt >= date }
        }
        if let until = args?["until"]?.stringValue, let date = parseDay(until) {
            // Inclusive of the whole day, not of midnight that morning.
            let endOfDay = date.addingTimeInterval(24 * 60 * 60)
            calls = calls.filter { $0.startedAt < endOfDay }
        }
        if let source = args?["source"]?.stringValue, !source.isEmpty {
            calls = calls.filter { $0.source.caseInsensitiveCompare(source) == .orderedSame }
        }
        if let speaker = args?["speaker"]?.stringValue, !speaker.isEmpty {
            calls = calls.filter { call in
                call.speakers.contains { $0.localizedCaseInsensitiveContains(speaker) }
            }
        }

        let total = calls.count
        let offset = max(0, args?["offset"]?.intValue ?? 0)
        let limit = clamp(args?["limit"]?.intValue ?? defaultCallLimit, 1, maxCallLimit)
        let page = Array(calls.dropFirst(offset).prefix(limit))

        guard !page.isEmpty else {
            return total == 0
                ? "No calls match those filters. \(TranscriptIndex.summaries().count) calls are indexed in total."
                : "No calls at offset \(offset) — there are \(total) matching calls."
        }

        var out = "\(total) matching call\(total == 1 ? "" : "s"), showing \(page.count) from offset \(offset):\n\n"
        for call in page {
            let speakers = call.speakers.isEmpty ? "no speech" : call.speakers.joined(separator: ", ")
            out += "- **\(call.id)** — \(human(call.startedAt)), \(call.source), "
            out += "\(call.durationMins) min, \(call.turnCount) turns — \(speakers)\n"
        }
        if offset + page.count < total {
            out += "\nMore available: call again with offset \(offset + page.count)."
        }
        return out
    }

    private static func getCall(_ args: [String: Value]?) throws -> String {
        try renderCall(resolveSummary(args?["id"]?.stringValue))
    }

    private static func getTranscript(_ args: [String: Value]?) throws -> String {
        let summary = try resolveSummary(args?["id"]?.stringValue)
        guard let record = TranscriptIndex.load(id: summary.id) else {
            throw ToolError(message: "The transcript for \(summary.id) could not be read. "
                + "Its note is at \(summary.notePath); run `ghostie index` to rebuild the index.")
        }

        var turns = record.turns
        guard !turns.isEmpty else {
            return "No speech was transcribed on \(record.id) (\(human(record.startedAt)))."
        }
        let totalTurns = turns.count

        var window = ""
        if let from = args?["from_time"]?.stringValue, let ms = parseClock(from) {
            turns = turns.filter { $0.ms >= ms }
            window += " from \(from)"
        }
        if let to = args?["to_time"]?.stringValue, let ms = parseClock(to) {
            turns = turns.filter { $0.ms <= ms }
            window += " to \(to)"
        }
        if let speaker = args?["speaker"]?.stringValue, !speaker.isEmpty {
            turns = turns.filter { $0.speaker.localizedCaseInsensitiveContains(speaker) }
            window += " by \(speaker)"
            if turns.isEmpty {
                throw ToolError(message: "No turns by \"\(speaker)\" in \(record.id). "
                    + "The speakers on this call are: \(record.speakers.joined(separator: ", ")).")
            }
        }
        guard !turns.isEmpty else {
            return "No turns\(window) in \(record.id). The call runs from "
                + "\(clock(record.turns.first!.ms)) to \(clock(record.turns.last!.ms))."
        }

        let matched = turns.count
        let offset = max(0, args?["offset"]?.intValue ?? 0)
        let limit = clamp(args?["limit"]?.intValue ?? defaultTurnLimit, 1, maxTurnLimit)
        let page = Array(turns.dropFirst(offset).prefix(limit))
        guard !page.isEmpty else {
            return "No turns at offset \(offset) — \(matched) turns match\(window)."
        }

        var out = "**\(record.id)** — \(human(record.startedAt)), \(record.source), \(record.durationMins) min\n"
        out += "Turns \(offset + 1)–\(offset + page.count) of \(matched)"
        out += matched == totalTurns ? "" : " matching\(window) (\(totalTurns) in the call)"
        out += "\n\n"
        for turn in page {
            out += "**[\(clock(turn.ms))] \(turn.speaker):** \(turn.text)\n\n"
        }
        if offset + page.count < matched {
            out += "— \(matched - offset - page.count) more turns. Continue with offset \(offset + page.count)."
        }
        return out
    }

    private static func searchCalls(_ args: [String: Value]?) throws -> String {
        guard let query = args?["query"]?.stringValue, !query.isEmpty else {
            throw ToolError(message: "search requires a non-empty `query`.")
        }
        let limit = clamp(args?["limit"]?.intValue ?? 25, 1, 100)
        let speaker = args?["speaker"]?.stringValue

        let scope: [TranscriptIndex.CallSummary]
        if let id = args?["id"]?.stringValue, !id.isEmpty {
            scope = [try resolveSummary(id)]
        } else {
            scope = TranscriptIndex.summaries()
            guard !scope.isEmpty else { throw noCallsError() }
        }

        var out = ""
        var hits = 0
        var callsWithHits = 0
        var truncated = false

        for call in scope {
            guard hits < limit else { truncated = true; break }
            guard let record = TranscriptIndex.load(id: call.id) else { continue }
            var matches = record.turns.filter { $0.text.localizedCaseInsensitiveContains(query) }
            if let speaker, !speaker.isEmpty {
                matches = matches.filter { $0.speaker.localizedCaseInsensitiveContains(speaker) }
            }
            guard !matches.isEmpty else { continue }

            callsWithHits += 1
            out += "### \(call.id) — \(human(call.startedAt)), \(call.source)\n"
            for turn in matches {
                if hits >= limit { truncated = true; break }
                out += "- **[\(clock(turn.ms))] \(turn.speaker):** \(turn.text)\n"
                hits += 1
            }
            out += "\n"
        }

        guard hits > 0 else {
            return "No call mentions \"\(query)\"" + (speaker.map { " from \($0)" } ?? "")
                + ". Searched \(scope.count) call\(scope.count == 1 ? "" : "s")."
        }
        var header = "\(hits) match\(hits == 1 ? "" : "es") for \"\(query)\" across "
        header += "\(callsWithHits) call\(callsWithHits == 1 ? "" : "s")"
        header += truncated ? " (stopped at the limit of \(limit) — narrow the query or pass a higher limit).\n\n" : ".\n\n"
        return header + out
    }

    private static func getStatus(_ config: Config) -> String {
        let calls = TranscriptIndex.summaries()
        var out = "**Ghostie \(Updater.runningVersion().raw)**\n\n"
        out += "- Notes folder: \(config.notesFolder)\n"
        out += "- Calls indexed: \(calls.count)\n"
        if let latest = calls.first {
            out += "- Most recent call: \(latest.id) (\(human(latest.startedAt)))\n"
        }
        let backlog = Backlog.pendingCount
        out += backlog == 0
            ? "- Retry backlog: empty\n"
            : "- Retry backlog: \(backlog) call\(backlog == 1 ? "" : "s") waiting to finish processing — "
              + "their notes exist but may be missing a summary.\n"

        // A note on disk that the index has never seen means the index is
        // stale, which is exactly the situation where "my call is missing"
        // gets asked.
        let noteCount = (try? FileManager.default.contentsOfDirectory(atPath: config.notesFolder))?
            .filter(TranscriptIndex.isNoteFile).count ?? 0
        if noteCount > calls.count {
            out += "- ⚠️ \(noteCount - calls.count) note(s) in the notes folder are not indexed. "
            out += "Run `ghostie index` in a terminal to pick them up.\n"
        }
        return out
    }

    // MARK: Resources

    /// Calls as resources so they can be @-mentioned in Claude Desktop
    /// without going through a tool call first. The note markdown, not the
    /// transcript: a resource is attached whole, and attaching an hour of
    /// speech by mention is not a thing anyone means to do.
    private static func registerResources(on server: Server, config: Config) async {
        await server.withMethodHandler(ListResources.self) { _ in
            let resources = TranscriptIndex.summaries().prefix(maxCallLimit).map { call in
                Resource(
                    name: "\(TranscriptIndex.title(for: call.source)) — \(human(call.startedAt))",
                    uri: "ghostie://call/\(call.id)",
                    description: call.speakers.isEmpty
                        ? "\(call.durationMins) minutes, no speech transcribed"
                        : "\(call.durationMins) minutes with \(call.speakers.joined(separator: ", "))",
                    mimeType: "text/markdown")
            }
            return .init(resources: Array(resources), nextCursor: nil)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            let prefix = "ghostie://call/"
            guard params.uri.hasPrefix(prefix) else {
                throw MCPError.invalidParams("Not a Ghostie call URI: \(params.uri)")
            }
            let id = String(params.uri.dropFirst(prefix.count))
            guard let call = TranscriptIndex.summaries().first(where: { $0.id == id }),
                  let note = try? String(contentsOfFile: call.notePath, encoding: .utf8)
            else {
                throw MCPError.invalidParams("No call with id \(id)")
            }
            return .init(contents: [.text(note, uri: params.uri, mimeType: "text/markdown")])
        }
    }

    // MARK: Prompts

    private static func registerPrompts(on server: Server) async {
        await server.withMethodHandler(ListPrompts.self) { _ in
            .init(prompts: [
                Prompt(
                    name: "call-recap",
                    description: "Catch up on a recorded call: what it was about, what was decided, what is open.",
                    arguments: [
                        .init(name: "call", description: "Call id, or \"latest\" (the default)", required: false)
                    ]),
                Prompt(
                    name: "action-items",
                    description: "Pull out who committed to what on a recorded call.",
                    arguments: [
                        .init(name: "call", description: "Call id, or \"latest\" (the default)", required: false)
                    ]),
            ], nextCursor: nil)
        }

        await server.withMethodHandler(GetPrompt.self) { params in
            let call = params.arguments?["call"] ?? "latest"
            switch params.name {
            case "call-recap":
                return .init(
                    description: "Recap of call \(call)",
                    messages: [.user(.text(text: """
                        Recap the Ghostie call with id "\(call)". Read its summary \
                        with ghostie_get_call, then use ghostie_get_transcript to \
                        check anything the summary leaves ambiguous.

                        Cover what the call was about, what was decided, and what \
                        was left open. Attribute points to the people who made \
                        them. Say when something was discussed but not resolved \
                        rather than presenting it as settled.
                        """))])
            case "action-items":
                return .init(
                    description: "Action items from call \(call)",
                    messages: [.user(.text(text: """
                        List the commitments made on the Ghostie call with id \
                        "\(call)". Read the summary with ghostie_get_call and \
                        check the transcript with ghostie_get_transcript — the \
                        summary may not carry every one.

                        For each: who committed, to what, and by when if a time \
                        was given. Quote the timestamp so it can be checked. \
                        Leave out things that were merely suggested and never \
                        picked up; note separately anything that sounded like a \
                        commitment but had no owner.
                        """))])
            default:
                throw MCPError.invalidParams("Unknown prompt: \(params.name)")
            }
        }
    }

    // MARK: Shared helpers

    /// Resolve an id argument, accepting "latest". The failure message names
    /// ids that do exist — a model that guessed an id needs the real ones, not
    /// to be told it was wrong.
    private static func resolveSummary(_ id: String?) throws -> TranscriptIndex.CallSummary {
        guard let id, !id.isEmpty else {
            throw ToolError(message: "This tool needs an `id` — a call id from ghostie_list_calls, or \"latest\".")
        }
        let calls = TranscriptIndex.summaries()
        guard !calls.isEmpty else { throw noCallsError() }

        if id.caseInsensitiveCompare("latest") == .orderedSame { return calls[0] }
        if let exact = calls.first(where: { $0.id == id }) { return exact }
        // A model that saw "2026-09-21_20-59-58_Zoom-Call" in one answer often
        // sends back the date alone. Accept an unambiguous prefix.
        let prefixed = calls.filter { $0.id.hasPrefix(id) }
        if prefixed.count == 1 { return prefixed[0] }

        if prefixed.count > 1 {
            throw ToolError(message: "\"\(id)\" matches \(prefixed.count) calls: "
                + prefixed.prefix(5).map(\.id).joined(separator: ", ") + ". Use the full id.")
        }
        let recent = calls.prefix(5).map(\.id).joined(separator: ", ")
        throw ToolError(message: "No call with id \"\(id)\". The most recent ids are: \(recent). "
            + "Use ghostie_list_calls to see more.")
    }

    private static func noCallsError() -> ToolError {
        ToolError(message: "Ghostie has not recorded any calls yet, or its notes folder has moved. "
            + "Check ghostie_get_status for where notes are being written.")
    }

    private static func renderCall(_ call: TranscriptIndex.CallSummary) -> String {
        var out = "# \(TranscriptIndex.title(for: call.source)) — \(human(call.startedAt))\n\n"
        out += "- id: `\(call.id)`\n"
        out += "- Duration: \(call.durationMins) minutes\n"
        out += "- Speakers: \(call.speakers.isEmpty ? "none (no speech transcribed)" : call.speakers.joined(separator: ", "))\n"
        out += "- Transcript: \(call.turnCount) turns — call ghostie_get_transcript with id `\(call.id)`\n\n"
        if let summary = TranscriptIndex.summaryText(ofNoteAt: call.notePath) {
            out += "---\n\n\(summary)\n"
        } else {
            out += "_(This call has no written summary yet — it may still be in the retry backlog. "
            out += "The transcript is available.)_\n"
        }
        return out
    }

    private static func clamp(_ value: Int, _ low: Int, _ high: Int) -> Int {
        min(max(value, low), high)
    }

    /// "MM:SS" or "HH:MM:SS" → milliseconds.
    private static func parseClock(_ text: String) -> Int? {
        let parts = text.split(separator: ":").map(String.init)
        guard parts.allSatisfy({ Int($0) != nil }) else { return nil }
        let numbers = parts.compactMap(Int.init)
        switch numbers.count {
        case 2: return (numbers[0] * 60 + numbers[1]) * 1000
        case 3: return (numbers[0] * 3600 + numbers[1] * 60 + numbers[2]) * 1000
        default: return nil
        }
    }

    private static func clock(_ ms: Int) -> String {
        let total = ms / 1000
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private static func parseDay(_ text: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: text)
    }

    private static let humanFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEEE d MMM yyyy 'at' HH:mm"
        return f
    }()

    private static func human(_ date: Date) -> String {
        humanFormatter.string(from: date)
    }
}
