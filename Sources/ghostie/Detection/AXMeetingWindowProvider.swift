import Foundation
import AppKit
import ApplicationServices

/// Queries Accessibility for Teams' top-level windows on a given main-app PID
/// and runs the title/role heuristics. Pull-based for task 4 (the coordinator
/// invokes `teamsHasMeetingWindow` on every evaluate); push-based AXObserver
/// integration is a follow-up perf optimization once we have live Teams
/// fixtures to drive it.
///
/// Permission lifecycle:
///   - `permissionGranted` reflects `AXIsProcessTrusted()` at query time,
///     so runtime revocation is picked up on the next evaluate.
///   - `promptForPermissionIfNeeded()` triggers the system prompt once on
///     first detector start. Denial is fine: the corroborator just stays
///     `.unavailable` and the rest of the pipeline still works.
final class AXMeetingWindowProvider: MeetingWindowProvider {

    private let heuristics: MeetingWindowHeuristics

    init(heuristics: MeetingWindowHeuristics = .default) {
        self.heuristics = heuristics
    }

    var permissionGranted: Bool { AXIsProcessTrusted() }

    @discardableResult
    func promptForPermissionIfNeeded() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options: NSDictionary = [key: true]
        return AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    func teamsHasMeetingWindow(mainAppPid: pid_t) -> MeetingWindowMatch {
        guard permissionGranted else {
            return .unavailable(reason: "Accessibility permission not granted")
        }
        let app = AXUIElementCreateApplication(mainAppPid)
        var ref: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            app, kAXWindowsAttribute as CFString, &ref)
        guard status == .success, let windows = ref as? [AXUIElement] else {
            // Common when the app is launching or quitting; treat as not-matched
            // rather than unavailable so the state machine can still rely on
            // other corroborators.
            return .notMatched
        }
        for window in windows {
            let attrs = Self.attributes(of: window)
            if let reason = heuristics.evaluate(attrs) {
                return .matched(reason: reason, heuristicsVersion: heuristics.version)
            }
        }
        return .notMatched
    }

    // MARK: - Reads

    private static func attributes(of window: AXUIElement) -> MeetingWindowHeuristics.Attributes {
        MeetingWindowHeuristics.Attributes(
            title:           string(window, kAXTitleAttribute as CFString),
            roleDescription: string(window, kAXRoleDescriptionAttribute as CFString),
            subrole:         string(window, kAXSubroleAttribute as CFString)
        )
    }

    private static func string(_ element: AXUIElement, _ attr: CFString) -> String {
        var ref: CFTypeRef?
        let s = AXUIElementCopyAttributeValue(element, attr, &ref)
        guard s == .success, let str = ref as? String else { return "" }
        return str
    }
}
