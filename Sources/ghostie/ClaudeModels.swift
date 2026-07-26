import Foundation

/// Which Claude writes the meeting note.
///
/// The picker used to be a hardcoded list of pinned version ids
/// (`claude-sonnet-4-6`, `claude-opus-4-7`, …), which meant it went stale the
/// moment Anthropic shipped anything — a model released after the last Ghostie
/// build simply wasn't offerable, and a config pinned to a retired id would
/// start failing with no way to fix it from Settings.
///
/// The fix is to stop listing versions. `claude --model sonnet` resolves to the
/// **latest** model in that tier — the CLI's own help documents the aliases as
/// "an alias for the latest model" — so an alias tracks Anthropic's releases on
/// its own and this file never needs editing when a new model ships. Anything
/// not covered by an alias is reachable by typing an exact id.
enum ClaudeModels {

    /// One tier. `id` is what goes to `claude -p --model`.
    struct Alias {
        let id: String
        let title: String
        let detail: String
    }

    /// The tiers the Claude CLI resolves to a current model. Ordered as the
    /// picker shows them: the sensible default first.
    ///
    /// This list is about *tiers*, not releases — adding a row here is only
    /// warranted if Anthropic introduces a genuinely new tier, not when a tier
    /// gets a new version.
    static let aliases: [Alias] = [
        Alias(id: "sonnet",
              title: "Sonnet",
              detail: "The balance most notes want — quick, and a strong writer."),
        Alias(id: "opus",
              title: "Opus",
              detail: "Better at long or tangled calls. Slower, and costs more of your quota."),
        Alias(id: "haiku",
              title: "Haiku",
              detail: "Fastest and lightest. Fine for short, straightforward calls."),
        Alias(id: "fable",
              title: "Fable",
              detail: "Anthropic's most capable model. Overkill for meeting notes, and priced like it.")
    ]

    static func alias(for id: String) -> Alias? {
        aliases.first { $0.id == id }
    }

    static func isAlias(_ id: String) -> Bool { alias(for: id) != nil }

    /// The default for a fresh install: an alias, so a new user is never
    /// pinned to whatever happened to be current on the day they installed.
    static let defaultModel = "sonnet"

    // MARK: Picker contents

    /// What a menu row stands for.
    enum Entry: Equatable {
        /// One of the tier aliases.
        case alias(String)
        /// A version the user pinned explicitly — shown so the picker states
        /// the truth about what's configured rather than silently displaying
        /// something else (`selectItem(withTitle:)` fails quietly on a miss,
        /// which is how the old picker could show `claude-sonnet-4-6` while
        /// the config said something entirely different).
        case pinned(String)
        /// Opens a prompt for an exact model id.
        case custom
    }

    /// The picker's rows for a given configured value, and which row is
    /// selected. Pure, so `selftest` can pin the "never misrepresents the
    /// config" property without building an NSPopUpButton.
    static func menu(configured: String) -> (entries: [Entry], selected: Int) {
        var entries: [Entry] = aliases.map { .alias($0.id) }
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, !isAlias(trimmed) {
            entries.append(.pinned(trimmed))
        }
        entries.append(.custom)
        let selected = entries.firstIndex {
            switch $0 {
            case .alias(let id):  return id == trimmed
            case .pinned(let id): return id == trimmed
            case .custom:         return false
            }
        }
        // An empty/whitespace configured value falls back to the default row
        // rather than leaving the picker on an arbitrary selection.
        return (entries, selected ?? entries.firstIndex(of: .alias(defaultModel)) ?? 0)
    }

    /// Menu title for a row.
    static func title(for entry: Entry) -> String {
        switch entry {
        case .alias(let id):
            guard let a = alias(for: id) else { return id }
            return "\(a.title) — latest"
        case .pinned(let id):
            return "\(id) (pinned)"
        case .custom:
            return "Use a specific version…"
        }
    }

    /// The sentence under the picker, describing whatever is selected. Written
    /// to say what the choice *means*, including the one thing a pinned id
    /// implies that an alias doesn't: it stops following new releases.
    static func summary(for configured: String) -> String {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        if let a = alias(for: trimmed) {
            return a.detail + " Follows Anthropic's latest \(a.title) automatically."
        }
        if trimmed.isEmpty {
            return "No model set — Ghostie will ask Claude Code for its default."
        }
        return "Pinned to \(trimmed). It won't move to newer models on its own, and note-writing will start failing if this version is retired."
    }
}
