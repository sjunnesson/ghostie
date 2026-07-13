import Foundation

/// Pure rules deciding whether a Teams window represents an in-meeting state.
/// Versioned so future Teams UI shifts can be tracked: a new shape ships as
/// a new constant (`v2 = MeetingWindowHeuristics(version: 2, rules: ...)`)
/// and we point `default` at it. Fixtures in
/// `runDetectorStateMachineSelfTest` pin each version's behavior.
///
/// The heuristics are deliberately conservative: a window that does not match
/// any rule yields `.notMatched`, not a false positive. AX in this detector
/// is a corroborator (not a veto), so a stale or fragile rule degrades the
/// confidence we have in a confirmed call but does not break detection of
/// real calls — output I/O and camera carry that weight.
struct MeetingWindowHeuristics {

    struct Attributes: Equatable {
        let title: String
        let roleDescription: String
        let subrole: String
    }

    let version: Int
    let rules: [Rule]

    struct Rule {
        let name: String
        let matches: (Attributes) -> Bool
    }

    func evaluate(_ attrs: Attributes) -> String? {
        for rule in rules where rule.matches(attrs) { return rule.name }
        return nil
    }

    /// v1: validated patterns only. We have no live Teams-meeting fixtures
    /// captured yet, so this errs toward false negatives over false
    /// positives. As we observe real meetings in `diagnose-detect`, bump to
    /// v2 with a wider net and a fixture per documented title shape.
    static let v1: MeetingWindowHeuristics = .init(version: 1, rules: [
        .init(name: "role description names meeting/call surface") { a in
            let r = a.roleDescription.lowercased()
            return r.contains("meeting controls") || r.contains("call window")
        },
        .init(name: "title 'Meeting with X | Microsoft Teams'") { a in
            a.title.range(of: #"^Meeting (with|in) .+ \| Microsoft Teams$"#,
                          options: .regularExpression) != nil
        },
        .init(name: "title 'Call with X | Microsoft Teams'") { a in
            a.title.range(of: #"^Call (with|in) .+ \| Microsoft Teams$"#,
                          options: .regularExpression) != nil
        },
    ])

    /// Zoom desktop (`us.zoom.xos`), for installs that add it to
    /// `triggerBundleIds`. Same philosophy as the Teams v1 set: only the
    /// stable, documented in-meeting window titles, no fuzzy matching — a
    /// miss just removes one corroborator (output I/O still carries the
    /// signal).
    static let zoomV1: MeetingWindowHeuristics = .init(version: 1, rules: [
        .init(name: "title 'Zoom Meeting'") { a in
            a.title == "Zoom Meeting" || a.title.hasPrefix("Zoom Meeting ")
        },
        .init(name: "title 'Zoom Webinar'") { a in
            a.title == "Zoom Webinar" || a.title.hasPrefix("Zoom Webinar ")
        },
    ])

    static let `default` = v1

    /// Rule set for a trigger app's bundle id. Unknown apps get the Teams
    /// rules — whose patterns cannot match other apps' windows, so this is
    /// equivalent to "no AX corroborator" rather than a false-positive risk.
    static func forBundleId(_ bundleId: String) -> MeetingWindowHeuristics {
        bundleId.lowercased().hasPrefix("us.zoom.") ? zoomV1 : v1
    }
}
