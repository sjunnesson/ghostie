import Foundation

/// Regression check for the MCP client registry.
///
/// A table of (name, path, key) rots quietly: a duplicated id shadows a
/// client, a mistyped key writes a valid JSON file that the client ignores,
/// and either one presents as "I connected it and nothing happened". None of
/// that shows up in a build. These checks are cheap and need no client
/// installed — they read the registry, not the disk.
func runMCPSetupSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "\n      \(detail)")") }
    }
    print("MCPSetup self-test")

    let clients = MCPSetup.knownClients
    check("the registry is not empty", !clients.isEmpty)

    let ids = clients.map(\.id)
    check("client ids are unique", Set(ids).count == ids.count, "\(ids)")
    check("client ids are lookup-safe",
          ids.allSatisfy { !$0.isEmpty && $0 == $0.lowercased() && !$0.contains(" ") }, "\(ids)")
    check("display names are unique", Set(clients.map(\.displayName)).count == clients.count)

    for client in clients {
        guard case .jsonFile(let paths, let key) = client.method else { continue }
        check("\(client.id): has at least one config path", !paths.isEmpty)
        check("\(client.id): config paths are absolute",
              paths.allSatisfy { $0.hasPrefix("/") }, "\(paths)")
        check("\(client.id): config paths are under the home directory",
              paths.allSatisfy { $0.hasPrefix(NSHomeDirectory()) }, "\(paths)")
        check("\(client.id): has a non-empty servers key", !key.isEmpty)
        // The one difference between clients that actually matters. Getting
        // it backwards writes a file the client reads and ignores.
        let expected = client.id == "vscode" ? "servers" : "mcpServers"
        check("\(client.id): uses the \(expected) key", key == expected, "got \(key)")
    }

    check("every client has a row symbol", clients.allSatisfy { !$0.symbol.isEmpty })
    check("every client explains itself",
          clients.allSatisfy { !$0.connectHint.isEmpty && !$0.connectedHint.isEmpty })

    // Lookup, as `ghostie connect <name>` does it.
    check("a client resolves by id", MCPSetup.client(id: "cursor")?.displayName == "Cursor")
    check("a client resolves by display name, ignoring case",
          MCPSetup.client(id: "claude desktop")?.id == "claude-desktop")
    check("an unknown client resolves to nothing", MCPSetup.client(id: "emacs") == nil)

    // The running-app guard only applies to files Ghostie writes itself.
    // CLI-managed clients are written by the vendor's own command and have no
    // app to quit, so a guard there would be a permanent, unfixable block.
    let cliClients = clients.filter { if case .cli = $0.method { return true }; return false }
    check("the registry has CLI-managed clients", !cliClients.isEmpty)
    check("CLI-managed clients are never blocked by the running-app guard",
          cliClients.allSatisfy { MCPSetup.blockingIssue($0) == nil })
    check("CLI-managed clients declare no app bundle",
          cliClients.allSatisfy { $0.appName == nil })
    for client in cliClients {
        guard case .cli(let spec) = client.method else { continue }
        let add = spec.add("/Applications/Ghostie.app/Contents/MacOS/ghostie")
        // Every one of these CLIs takes `mcp <verb> <name>`; a reordering
        // would register under the wrong name or fail with a usage error.
        check("\(client.id): add starts `mcp add ghostie`",
              Array(add.prefix(3)) == ["mcp", "add", "ghostie"], "\(add)")
        check("\(client.id): add passes the binary after a -- separator",
              add.contains("--")
                  && add.suffix(2) == ["/Applications/Ghostie.app/Contents/MacOS/ghostie", "mcp"],
              "\(add)")
        check("\(client.id): remove targets the same name",
              Array(spec.remove.prefix(3)) == ["mcp", "remove", "ghostie"], "\(spec.remove)")
        check("\(client.id): get targets the same name",
              Array(spec.get.prefix(3)) == ["mcp", "get", "ghostie"], "\(spec.get)")
        check("\(client.id): names a binary", !spec.binary.isEmpty)
    }
    check("claude-code is in the registry", MCPSetup.client(id: "claude-code") != nil)
    check("codex is in the registry", MCPSetup.client(id: "codex") != nil)
    check("file-backed clients name an app to quit",
          clients.allSatisfy { client in
              if case .jsonFile = client.method { return client.appName != nil }
              return true
          })

    // The snippet is the escape hatch for every client not in the table, so
    // it has to be valid JSON of the exact shape clients expect.
    for key in ["mcpServers", "servers"] {
        let snippet = MCPSetup.configSnippet(key: key)
        guard let data = snippet.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root[key] as? [String: Any],
              let entry = servers["ghostie"] as? [String: Any]
        else {
            check("the \(key) snippet is well-formed JSON", false, snippet)
            continue
        }
        check("the \(key) snippet is well-formed JSON", true)
        check("the \(key) snippet carries an absolute command",
              (entry["command"] as? String)?.hasPrefix("/") == true)
        check("the \(key) snippet passes the mcp subcommand",
              entry["args"] as? [String] == ["mcp"])
        // Paths must survive verbatim — an escaped slash is still valid JSON
        // but is exactly the kind of thing that looks wrong when pasted.
        check("the \(key) snippet does not escape slashes", !snippet.contains("\\/"))
    }
    let bare = MCPSetup.configSnippet(key: nil)
    check("the keyless snippet is the bare entry",
          bare.contains("\"ghostie\"") && !bare.contains("mcpServers"), bare)

    // A build-directory path is the one thing worth warning about: that
    // binary gets deleted and the client then fails with "server
    // disconnected" and nothing else.
    check("a build path is recognised as transient",
          MCPSetup.isTransientPath("/Users/x/code/ghostie/.build/release/ghostie"))
    check("an installed path is not transient",
          !MCPSetup.isTransientPath("/Applications/Ghostie.app/Contents/MacOS/ghostie"))

    check("the registered path is absolute", MCPSetup.executablePath().hasPrefix("/"))
    check("home is abbreviated for display",
          MCPSetup.abbreviate("\(NSHomeDirectory())/.cursor/mcp.json") == "~/.cursor/mcp.json")

    print("MCPSetup: \(passed) passed, \(failed) failed")
    return failed == 0
}
