import Foundation
import ApplicationServices

/// AX window-title probe for Teams meetings running inside a browser
/// (`detectBrowserTeams`). A browser window's title reflects its active tab,
/// and an in-meeting teams.microsoft.com tab titles itself with a meeting/
/// call phrase plus the "| Microsoft Teams" suffix (browsers may append
/// their own " — Chrome"-style tail, so nothing here anchors to the end).
///
/// Deliberately conservative, like `MeetingWindowHeuristics`: the title must
/// carry BOTH the Teams marker and a meeting-ish word. A background Teams
/// tab sitting on chat/activity ("Chat | Microsoft Teams") does not qualify,
/// so browser mic use for some other site never becomes a primary signal
/// just because Teams is open in another tab. False negatives cost one
/// corroborator; false positives could record a non-call — so we err hard
/// toward the former. Rules are static + pure (`titleLooksLikeMeetingTab`)
/// for the selftest.
final class AXBrowserTabProvider: BrowserTabProvider {

    var permissionGranted: Bool { AXIsProcessTrusted() }

    func pidsWithMeetingTab(browsers: [RunningAppInfo]) -> [pid_t] {
        guard permissionGranted else { return [] }
        var out: [pid_t] = []
        for browser in browsers {
            let app = AXUIElementCreateApplication(browser.pid)
            var ref: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(
                app, kAXWindowsAttribute as CFString, &ref)
            guard status == .success, let windows = ref as? [AXUIElement] else { continue }
            for window in windows {
                var titleRef: CFTypeRef?
                guard AXUIElementCopyAttributeValue(
                        window, kAXTitleAttribute as CFString, &titleRef) == .success,
                      let title = titleRef as? String else { continue }
                if Self.titleLooksLikeMeetingTab(title) {
                    out.append(browser.pid)
                    break
                }
            }
        }
        return out.sorted()
    }

    /// True for browser-window titles that look like an ACTIVE Teams meeting
    /// tab. Requires the "Microsoft Teams" marker AND a meeting/call word so
    /// a background chat tab never qualifies.
    static func titleLooksLikeMeetingTab(_ title: String) -> Bool {
        let t = title.lowercased()
        guard t.contains("microsoft teams") else { return false }
        return t.contains("meeting") || t.contains("call")
            || t.contains("möte") || t.contains("samtal")
    }
}
