import AppKit
import Foundation

/// Registering `ghostie mcp` with the assistants that can use it.
///
/// The server itself is plain MCP over stdio and cares about none of this —
/// anything that speaks the protocol can launch it. What differs per client
/// is only *where it is written down*, and almost every client has settled on
/// the same shape: a `command` + `args` pair under a named key in a JSON file.
/// So this is a small registry of (name, file, key) rather than a special case
/// per app.
///
/// Two rules keep the registry honest:
///
/// 1. **A client is only offered when it is actually installed.** A wrong path
///    then costs nothing, because nothing is written for an app that isn't
///    there. Installing the app later makes the row appear.
/// 2. **A running client is never written to.** Claude Desktop keeps the
///    config in memory and rewrites the whole file when any of its own
///    settings change — observed live: adding Ghostie's entry, then dragging
///    a pane in Claude Desktop, and the entry was gone. Every client that
///    owns its config file this way can do the same, so `connect` refuses
///    while the app is running and says which app to quit. Silently losing
///    the entry is worse than an extra step, because the failure looks like
///    the feature not working.
/// 3. **Clients whose schema differs are not guessed at.** Zed nests
///    `command` inside its own object under `context_servers`, Goose keeps
///    YAML; both are covered by `configSnippet()` — the copyable JSON — rather
///    than by code that has never run against them. Writing a malformed entry
///    into someone's editor settings is worse than not offering the button.
///
/// Nothing here connects Ghostie to anything. It writes the client's config so
/// that *the client* knows how to launch `ghostie mcp` — the server only ever
/// runs as a child of the assistant, on demand, reading the notes folder.
enum MCPSetup {

    /// The name the server is registered under, everywhere.
    static let serverKey = "ghostie"

    // MARK: The client registry

    struct Client: Sendable, Identifiable {
        let id: String
        let displayName: String
        let method: Method
        /// SF Symbol for the settings row.
        let symbol: String
        /// The `/Applications` bundle name, when there is one. Used both to
        /// detect the app and to notice it is running before writing a file
        /// it owns.
        let appName: String?
        /// What the user gets once this one is connected.
        let connectedHint: String
        /// What they should expect when pressing Connect.
        let connectHint: String
        /// Is the app on this machine at all? Takes the config because
        /// finding Claude Code means finding its CLI, and that path is
        /// user-overridable — detecting with defaults while connecting with
        /// the real value would hide the row from exactly the people who
        /// configured it.
        let isInstalled: @Sendable (Config) -> Bool
    }

    enum Method: Sendable {
        /// Merge `{"command": …, "args": ["mcp"]}` under `key` in the first of
        /// `paths` that exists (or the first one, when none do yet).
        case jsonFile(paths: [String], key: String)
        /// A client that owns its config through its own CLI — Claude Code
        /// (`~/.claude.json`) and Codex (`~/.codex/config.toml`). Both
        /// migrate their format between releases, and Codex's is TOML, which
        /// cannot be merged safely without a parser Ghostie does not have.
        /// Driving the vendor's own command sidesteps both problems, and it
        /// fails loudly (non-zero exit, real message) rather than silently
        /// writing something the client ignores.
        case cli(CLISpec)
    }

    /// How to drive one client's MCP subcommand.
    struct CLISpec: Sendable {
        /// Executable name, looked up in the usual install dirs and then on
        /// PATH — the app is launched from Finder, where PATH is barely
        /// anything, so the hardcoded directories are the ones that matter.
        let binary: String
        /// A user-configured override, when the client has one.
        let configuredPath: @Sendable (Config) -> String?
        /// Args for `add`, given the path to register.
        let add: @Sendable (String) -> [String]
        let remove: [String]
        let get: [String]
    }

    /// Common places a user-installed CLI lands, in the order they usually
    /// shadow each other, then PATH.
    private static func findExecutable(_ name: String, configured: String?) -> String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let configured, !configured.isEmpty { candidates.append(configured) }
        candidates += [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
            "\(home)/.bun/bin/\(name)",
            "\(home)/.volta/bin/\(name)",
        ]
        candidates += (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map { "\($0)/\(name)" }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    private static func appExists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: "/Applications/\(name).app")
    }
    private static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
    private static var home: String { NSHomeDirectory() }

    /// Every client Ghostie knows how to write, installed or not.
    ///
    /// Ordered roughly by how likely someone reading this is to have one.
    static var knownClients: [Client] {
        [
            Client(
                id: "claude-desktop",
                displayName: "Claude Desktop",
                method: .jsonFile(
                    paths: ["\(home)/Library/Application Support/Claude/claude_desktop_config.json"],
                    key: "mcpServers"),
                symbol: "bubble.left.and.bubble.right.fill",
                appName: "Claude",
                connectedHint: "Ask about a call in any conversation.",
                connectHint: "Picked up the next time Claude Desktop starts.",
                isInstalled: { _ in
                    appExists("Claude")
                        || exists("\(home)/Library/Application Support/Claude/claude_desktop_config.json")
                }),

            Client(
                id: "claude-code",
                displayName: "Claude Code",
                method: .cli(CLISpec(
                    binary: "claude",
                    configuredPath: { $0.claudeBinary },
                    // --scope user so it is there in every project, not only
                    // whichever directory happened to be current.
                    add: { ["mcp", "add", serverKey, "--scope", "user", "--", $0, "mcp"] },
                    remove: ["mcp", "remove", serverKey, "--scope", "user"],
                    get: ["mcp", "get", serverKey])),
                symbol: "terminal.fill",
                appName: nil,
                connectedHint: "Ask about a call from `claude`, in any project.",
                connectHint: "Registered for every project, via `claude mcp add`.",
                isInstalled: { cliPath(for: "claude", configured: $0.claudeBinary) != nil }),

            Client(
                id: "codex",
                displayName: "Codex",
                // Codex keeps MCP servers in ~/.codex/config.toml, and its
                // CLI, desktop app and IDE extension all read the same file —
                // so registering once covers all three.
                method: .cli(CLISpec(
                    binary: "codex",
                    configuredPath: { _ in nil },
                    add: { ["mcp", "add", serverKey, "--", $0, "mcp"] },
                    remove: ["mcp", "remove", serverKey],
                    get: ["mcp", "get", serverKey])),
                symbol: "chevron.left.slash.chevron.right",
                appName: nil,
                connectedHint: "Ask about a call from `codex`, and in the Codex app.",
                connectHint: "Registered via `codex mcp add`, shared with the Codex app and IDE extension.",
                isInstalled: { _ in cliPath(for: "codex", configured: nil) != nil }),

            Client(
                id: "cursor",
                displayName: "Cursor",
                method: .jsonFile(paths: ["\(home)/.cursor/mcp.json"], key: "mcpServers"),
                symbol: "cursorarrow.rays",
                appName: "Cursor",
                connectedHint: "Available to Cursor's agent in every project.",
                connectHint: "Written to ~/.cursor/mcp.json.",
                isInstalled: { _ in appExists("Cursor") || exists("\(home)/.cursor") }),

            Client(
                id: "vscode",
                displayName: "VS Code",
                // VS Code is the one that does not use `mcpServers` — its user
                // `mcp.json` keys servers under `servers`. The path is the
                // default profile's; a custom profile keeps its own, and that
                // case is what "Copy configuration" is for.
                method: .jsonFile(
                    paths: ["\(home)/Library/Application Support/Code/User/mcp.json"],
                    key: "servers"),
                symbol: "chevron.left.forwardslash.chevron.right",
                appName: "Visual Studio Code",
                connectedHint: "Available to Copilot's agent mode.",
                connectHint: "Written to VS Code's default profile.",
                isInstalled: { _ in
                    appExists("Visual Studio Code")
                        || exists("\(home)/Library/Application Support/Code/User")
                }),

            Client(
                id: "windsurf",
                displayName: "Windsurf",
                method: .jsonFile(
                    paths: ["\(home)/.codeium/windsurf/mcp_config.json"], key: "mcpServers"),
                symbol: "wind",
                appName: "Windsurf",
                connectedHint: "Available to Cascade.",
                connectHint: "Written to ~/.codeium/windsurf/mcp_config.json.",
                isInstalled: { _ in appExists("Windsurf") || exists("\(home)/.codeium/windsurf") }),

            Client(
                id: "lm-studio",
                displayName: "LM Studio",
                // LM Studio documents ~/.lmstudio but has shipped builds that
                // read ~/.cache/lm-studio instead, so take whichever exists.
                method: .jsonFile(
                    paths: ["\(home)/.lmstudio/mcp.json", "\(home)/.cache/lm-studio/mcp.json"],
                    key: "mcpServers"),
                symbol: "cpu",
                appName: "LM Studio",
                connectedHint: "Your local models can read your calls.",
                connectHint: "Written to LM Studio's mcp.json.",
                isInstalled: { _ in
                    appExists("LM Studio") || exists("\(home)/.lmstudio")
                        || exists("\(home)/.cache/lm-studio")
                }),
        ]
    }

    /// The clients actually present on this machine.
    static func installedClients(_ config: Config) -> [Client] {
        knownClients.filter { $0.isInstalled(config) }
    }

    static func client(id: String) -> Client? {
        knownClients.first { $0.id == id }
            ?? knownClients.first { $0.displayName.caseInsensitiveCompare(id) == .orderedSame }
    }

    // MARK: Status

    enum Status: Equatable, Sendable {
        case connected
        /// Registered, but launching a different copy of Ghostie — usually one
        /// registered from a build directory before the app was installed.
        case connectedToOtherPath(String)
        case notConnected
        case unavailable(String)

        var isConnected: Bool {
            switch self {
            case .connected, .connectedToOtherPath: return true
            case .notConnected, .unavailable: return false
            }
        }
    }

    static func status(_ client: Client, config: Config) -> Status {
        guard client.isInstalled(config) else {
            return .unavailable("\(client.displayName) is not installed.")
        }
        switch client.method {
        case .jsonFile(let paths, let key):
            guard let path = paths.first(where: exists),
                  let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = root[key] as? [String: Any],
                  let entry = servers[serverKey] as? [String: Any],
                  let command = entry["command"] as? String
            else { return .notConnected }
            return command == executablePath() ? .connected : .connectedToOtherPath(command)

        case .cli(let spec):
            return cliStatus(spec, config: config, name: client.displayName)
        }
    }

    // MARK: The running-client guard

    /// Is the app currently running? Matched on the bundle path rather than a
    /// bundle identifier so the registry needs one fact per client, not two.
    static func isRunning(_ client: Client) -> Bool {
        guard let appName = client.appName else { return false }
        let bundlePath = "/Applications/\(appName).app"
        return NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.standardizedFileURL.path == bundlePath
        }
    }

    /// Why this client cannot be written to right now, or nil when it can.
    ///
    /// Only file-backed clients are blocked. A CLI-managed client is written
    /// by the vendor's own command — the process that owns the file — so it
    /// is safe to do while the client is running.
    static func blockingIssue(_ client: Client) -> String? {
        guard case .jsonFile = client.method, isRunning(client) else { return nil }
        return "Quit \(client.displayName) first, then try again. It keeps its settings in "
            + "memory and rewrites this whole file whenever any of them change, which would "
            + "silently discard Ghostie's entry."
    }

    // MARK: Connect / disconnect

    static func connect(_ client: Client, config: Config) -> Result<String, Error> {
        if let issue = blockingIssue(client) { return .failure(SetupError(issue)) }
        switch client.method {
        case .jsonFile(let paths, let key):
            return writeJSONEntry(paths: paths, key: key, remove: false,
                                  clientName: client.displayName)
        case .cli(let spec):
            return cliConnect(spec, config: config, name: client.displayName)
        }
    }

    static func disconnect(_ client: Client, config: Config) -> Result<String, Error> {
        if let issue = blockingIssue(client) { return .failure(SetupError(issue)) }
        switch client.method {
        case .jsonFile(let paths, let key):
            return writeJSONEntry(paths: paths, key: key, remove: true,
                                  clientName: client.displayName)
        case .cli(let spec):
            return cliDisconnect(spec, config: config, name: client.displayName)
        }
    }

    /// Add or remove Ghostie's one entry in a client's JSON config.
    ///
    /// These files are the user's and hold far more than MCP servers —
    /// editor preferences, other servers, API tokens for them. So this decodes
    /// the whole document into an untyped dictionary, changes exactly one key,
    /// and writes the rest back untouched. Anything less careful would
    /// silently discard settings that cannot easily be recreated, and on a
    /// first edit it keeps a `.ghostie-backup` beside the original.
    private static func writeJSONEntry(paths: [String], key: String, remove: Bool,
                                       clientName: String) -> Result<String, Error> {
        let path = paths.first(where: exists) ?? paths[0]
        let url = URL(fileURLWithPath: path)
        do {
            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                guard let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    // Almost always a config with comments in it — VS Code's
                    // JSONC is the common case, and a strict parser cannot
                    // safely rewrite one.
                    throw SetupError("\(abbreviate(path)) could not be read as plain JSON "
                        + "(it may contain comments). Ghostie will not overwrite it — "
                        + "add the entry from “Copy configuration” instead.")
                }
                root = parsed
                try? data.write(to: URL(fileURLWithPath: path + ".ghostie-backup"), options: .atomic)
            } else if remove {
                return .success("Ghostie was not registered with \(clientName).")
            }

            var servers = root[key] as? [String: Any] ?? [:]
            if remove {
                guard servers[serverKey] != nil else {
                    return .success("Ghostie was not registered with \(clientName).")
                }
                servers.removeValue(forKey: serverKey)
            } else {
                servers[serverKey] = serverEntry()
            }
            root[key] = servers

            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let out = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            try out.write(to: url, options: .atomic)
            return .success(remove
                ? "Removed from \(abbreviate(path))."
                : "Added to \(abbreviate(path)).")
        } catch {
            return .failure(error)
        }
    }

    // MARK: CLI-managed clients

    /// Resolve a client's CLI, or nil when it isn't installed.
    static func cliPath(for binary: String, configured: String?) -> String? {
        findExecutable(binary, configured: configured)
    }

    private static func resolve(_ spec: CLISpec, _ config: Config) -> String? {
        findExecutable(spec.binary, configured: spec.configuredPath(config))
    }

    private static func cliConnect(_ spec: CLISpec, config: Config,
                                   name: String) -> Result<String, Error> {
        guard let binary = resolve(spec, config) else {
            return .failure(SetupError("Could not find the `\(spec.binary)` CLI. "
                + "Install \(name), or put it on PATH."))
        }
        // Remove first so re-registering repoints an existing entry rather
        // than failing on the name already being taken.
        _ = runProcess(binary, spec.remove, stderrToNull: true)
        let add = runProcess(binary, spec.add(executablePath()))
        guard add.status == 0 else {
            return .failure(SetupError("`\(spec.binary) \(spec.add(executablePath())[0...1].joined(separator: " "))` failed: "
                + add.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success("Added to \(name).")
    }

    private static func cliDisconnect(_ spec: CLISpec, config: Config,
                                      name: String) -> Result<String, Error> {
        guard let binary = resolve(spec, config) else {
            return .failure(SetupError("Could not find the `\(spec.binary)` CLI."))
        }
        let result = runProcess(binary, spec.remove)
        guard result.status == 0 else {
            return .failure(SetupError(result.output.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        return .success("Removed from \(name).")
    }

    private static func cliStatus(_ spec: CLISpec, config: Config, name: String) -> Status {
        guard let binary = resolve(spec, config) else {
            return .unavailable("The `\(spec.binary)` CLI was not found.")
        }
        let result = runProcess(binary, spec.get, stderrToNull: true)
        guard result.status == 0 else { return .notConnected }
        if result.output.contains(executablePath()) { return .connected }
        // These CLIs print the command they will run on a labelled line
        // ("  Command: /path/to/ghostie"). Take the path, not the whole line
        // — this string lands in a sentence in the settings pane, and
        // "(Command: /Applications/…)" reads like a bug.
        for line in result.output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let slash = trimmed.firstIndex(of: "/"),
                  trimmed.contains("ghostie") else { continue }
            return .connectedToOtherPath(String(trimmed[slash...]))
        }
        return .connected
    }

    // MARK: The binary, and the snippet for everything else

    /// The path a client should launch.
    ///
    /// Inside `Ghostie.app` this is the bundled executable, which is the one
    /// worth registering: it stays valid across in-place updates, and it is
    /// the copy that holds the app's microphone and screen-recording consent.
    /// A `swift run` build registers its own binary so the feature can be
    /// developed without installing the app.
    static func executablePath() -> String {
        if let path = Bundle.main.executablePath, !path.isEmpty { return path }
        return CommandLine.arguments[0]
    }

    /// True when the binary being registered lives in a build directory.
    /// Worth saying out loud: `swift build` output is routinely deleted, and a
    /// client pointed at a deleted binary fails with nothing more helpful than
    /// "server disconnected".
    static func isTransientPath(_ path: String) -> Bool {
        path.contains("/.build/") || path.hasPrefix(FileManager.default.temporaryDirectory.path)
    }

    private static func serverEntry() -> [String: Any] {
        ["command": executablePath(), "args": ["mcp"]]
    }

    /// The config block to paste into any MCP client Ghostie doesn't write
    /// itself — Zed, Goose, Cline, a self-hosted agent, whatever comes next.
    ///
    /// `key` is the only thing clients disagree about: nearly all of them use
    /// `mcpServers`, VS Code uses `servers`. Passing nil emits the bare entry
    /// for a client that wants just the server object.
    static func configSnippet(key: String? = "mcpServers") -> String {
        let bare: [String: Any] = [serverKey: serverEntry()]
        let entry: Any = key.map { [$0: bare] as [String: Any] } ?? bare
        guard let data = try? JSONSerialization.data(
            withJSONObject: entry,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return "" }
        return text
    }

    static func abbreviate(_ path: String) -> String {
        path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    struct SetupError: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
