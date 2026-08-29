import Foundation
import ApplicationServices

/// Who is actually in the meeting, read off the meeting UI over Accessibility.
///
/// Diarization can tell voices apart and `SpeakerNamer` can read names out of
/// the conversation, but neither knows the *spelling* or whether a name it
/// found belongs to someone in the room at all. The meeting window already
/// lists everyone by name; this reads that list, and the names become a
/// closed set the naming pass has to choose from.
///
/// Verified against Google Meet in Chrome (2026-08-29) — Chrome builds its web
/// accessibility tree on demand the first time AX queries arrive, so no
/// `AXManualAccessibility` poke is needed (that attribute is gone; setting it
/// returns -25205). Two shapes carry names:
///
///   • **the People side panel — the one that actually works.** Measured
///     end-to-end: with it open the roster reads out complete, with the local
///     user marked. With it *closed*, a solo Meet exposed no participant name
///     anywhere in the tree, so this is the whole feature in practice: a
///     roster is captured when (and only when) the user has that panel open
///     at some point during the call. Sampling runs throughout, so opening it
///     once is enough.
///
///         AXList  ⟨Participants⟩
///           AXGroup  ⟨David Sjunnesson⟩
///             AXStaticText  ⟨David Sjunnesson⟩
///             AXStaticText  ⟨(You)⟩
///
///   • per-tile menu buttons, `AXPopUpButton ⟨More options for <Name>⟩`.
///     **Opportunistic, not relied on.** In a solo call this element proved
///     hover-transient: present in one sample, gone from the next with the
///     page untouched. Whether a multi-participant call keeps tile names
///     mounted was not measurable with one person, so the rule is kept
///     (it is precise — nothing else is labelled this way) but nothing is
///     promised by it. If it ever needs to be relied on, verify it in a real
///     call first with `ghostie roster-probe`.
///
/// Sampled repeatedly through a call and unioned, so a roster is captured
/// whenever either shape happens to be visible. Finding nothing is normal and
/// costs nothing: naming falls back to reading names out of the transcript.
///
/// **Locale:** the tile rule keys on an English aria-label, as
/// `MeetingWindowHeuristics` already does. The panel rule is structural (a
/// list of groups whose title repeats as their own static text) and does not
/// depend on the UI language, so a non-English user still gets a roster when
/// the People panel is open. Both rules are pure over `RosterNode` and
/// covered by `selftest`.
protocol ParticipantRosterProvider: AnyObject {
    func roster(browsers: [RunningAppInfo]) -> MeetingRoster
}

/// Names read off a meeting window. `others` excludes the local user, who is
/// the one label naming never has to guess.
struct MeetingRoster: Equatable {
    var others: [String] = []
    var selfName: String?

    var isEmpty: Bool { others.isEmpty && selfName == nil }

    /// Union, preserving first-seen order. A call is sampled repeatedly and
    /// people join late, so the roster only ever grows.
    func merged(with other: MeetingRoster) -> MeetingRoster {
        var names = others
        for n in other.others where !names.contains(n) { names.append(n) }
        return MeetingRoster(others: names, selfName: selfName ?? other.selfName)
    }
}

/// The slice of an AX element the roster rules look at. Lifting the tree into
/// this makes the rules pure — the self-test builds one by hand from the real
/// Meet dump instead of needing a live meeting.
struct RosterNode {
    var role: String
    var title: String = ""
    var children: [RosterNode] = []

    /// Titles of this node's immediate static-text children.
    var staticTexts: [String] {
        children.filter { $0.role == "AXStaticText" }.map(\.title)
    }
}

enum RosterHeuristics {
    /// Meet marks the local user's row with this. Localized, so its absence
    /// only means "self unknown" — never that a row belongs to someone else.
    static let selfMarker = "(You)"
    /// English-only tile rule; see the type doc.
    static let tileMenuPrefix = "more options for "

    /// Every name the tree carries, from both shapes.
    static func roster(in root: RosterNode) -> MeetingRoster {
        var out = MeetingRoster()
        walk(root, into: &out)
        return out
    }

    private static func walk(_ node: RosterNode, into out: inout MeetingRoster) {
        if let list = participantList(node) {
            for row in list {
                guard SpeakerNamer.isPlausibleName(row.name) else { continue }
                if row.isSelf { out.selfName = out.selfName ?? row.name }
                else if !out.others.contains(row.name) { out.others.append(row.name) }
            }
        }
        if let name = tileName(node), SpeakerNamer.isPlausibleName(name),
           !out.others.contains(name) {
            out.others.append(name)
        }
        for child in node.children { walk(child, into: &out) }
    }

    /// Rows of a participants list, or nil when `node` isn't one.
    ///
    /// Structural on purpose: an `AXList` whose child groups each carry a
    /// non-empty title that also appears among their own static texts. That
    /// "the title is repeated as visible text" test is what separates a
    /// roster from the many other lists a meeting page contains — a list of
    /// buttons or messages doesn't echo its accessible name as a child label.
    static func participantList(_ node: RosterNode) -> [(name: String, isSelf: Bool)]? {
        guard node.role == "AXList" else { return nil }
        let groups = node.children.filter { $0.role == "AXGroup" && !$0.title.isEmpty }
        guard !groups.isEmpty else { return nil }
        var rows: [(name: String, isSelf: Bool)] = []
        for g in groups {
            let texts = g.staticTexts
            guard texts.contains(g.title) else { return nil }
            rows.append((name: g.title,
                         isSelf: texts.contains { $0.caseInsensitiveCompare(selfMarker) == .orderedSame }))
        }
        return rows
    }

    /// The participant a per-tile menu button names, or nil.
    static func tileName(_ node: RosterNode) -> String? {
        guard node.role == "AXPopUpButton" || node.role == "AXButton" else { return nil }
        let t = node.title.trimmingCharacters(in: .whitespaces)
        guard t.lowercased().hasPrefix(tileMenuPrefix), t.count > tileMenuPrefix.count
        else { return nil }
        return String(t.dropFirst(tileMenuPrefix.count)).trimmingCharacters(in: .whitespaces)
    }
}

/// Live implementation. Walks only the windows of browsers the tab probe
/// already flagged as showing a meeting, bounded in depth and node count —
/// this runs during a call, on a Chrome tree that can be enormous.
final class AXParticipantRosterProvider: ParticipantRosterProvider {

    /// A meeting page's roster sits well inside the web area; 45 clears it
    /// with room to spare on the trees measured in Meet.
    private let maxDepth = 45
    /// Ceiling per window. The measured Meet page is a few thousand nodes;
    /// beyond this we are walking something else and should stop paying.
    private let maxNodes = 6_000

    var permissionGranted: Bool { AXIsProcessTrusted() }

    func roster(browsers: [RunningAppInfo]) -> MeetingRoster {
        guard permissionGranted else { return MeetingRoster() }
        var out = MeetingRoster()
        for browser in browsers {
            let app = AXUIElementCreateApplication(browser.pid)
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                    app, kAXWindowsAttribute as CFString, &ref) == .success,
                  let windows = ref as? [AXUIElement] else { continue }
            for window in windows {
                var budget = maxNodes
                let tree = Self.snapshot(window, depth: 0, maxDepth: maxDepth, budget: &budget)
                out = out.merged(with: RosterHeuristics.roster(in: tree))
            }
        }
        return out
    }

    /// Depth- and budget-bounded lift of an AX subtree into `RosterNode`.
    private static func snapshot(_ element: AXUIElement, depth: Int,
                                 maxDepth: Int, budget: inout Int) -> RosterNode {
        budget -= 1
        var node = RosterNode(role: string(element, kAXRoleAttribute as CFString),
                              title: label(element))
        guard depth < maxDepth, budget > 0 else { return node }
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                element, kAXChildrenAttribute as CFString, &ref) == .success,
              let kids = ref as? [AXUIElement] else { return node }
        for kid in kids {
            if budget <= 0 { break }
            node.children.append(snapshot(kid, depth: depth + 1,
                                          maxDepth: maxDepth, budget: &budget))
        }
        return node
    }

    /// Meet puts the name in the accessible title on tiles and rows, and in
    /// the value on some static texts, so both are consulted — title first.
    private static func label(_ e: AXUIElement) -> String {
        let title = string(e, kAXTitleAttribute as CFString)
        if !title.isEmpty { return title }
        let desc = string(e, kAXDescriptionAttribute as CFString)
        if !desc.isEmpty { return desc }
        return string(e, kAXValueAttribute as CFString)
    }

    private static func string(_ element: AXUIElement, _ attr: CFString) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr, &ref) == .success,
              let s = ref as? String else { return "" }
        return s
    }
}
