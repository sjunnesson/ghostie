import Foundation
import ApplicationServices

/// AX window-title probe for meetings running inside a browser
/// (`detectBrowserMeetings`) — teams.microsoft.com and meet.google.com. A
/// browser window's title reflects its active tab: an in-meeting Teams tab
/// titles itself with a meeting/call phrase plus the "| Microsoft Teams"
/// suffix, and an in-meeting Google Meet tab titles itself "Meet – <code>"
/// (browsers may append their own " — Chrome"-style tail, so nothing here
/// anchors to the end).
///
/// Deliberately conservative, like `MeetingWindowHeuristics`: the Teams rule
/// requires BOTH the Teams marker and a meeting-ish word, and the Meet rule
/// requires the "Meet – " tab-title prefix. A background Teams tab sitting on
/// chat/activity ("Chat | Microsoft Teams") does not qualify, and neither
/// does the Meet landing page ("Google Meet") or a random page with "meet" in
/// its title — so browser mic use for some other site never becomes a primary
/// signal. False negatives cost one corroborator; false positives could
/// record a non-call — so we err hard toward the former. Rules are static +
/// pure (`meetingSite(forTitle:)`) for the selftest.
final class AXBrowserTabProvider: BrowserTabProvider {

    var permissionGranted: Bool { AXIsProcessTrusted() }

    func meetingTabs(browsers: [RunningAppInfo]) -> [pid_t: CallSource] {
        guard permissionGranted else { return [:] }
        var out: [pid_t: CallSource] = [:]
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
                if let site = Self.meetingSite(forTitle: title) {
                    out[browser.pid] = site
                    break
                }
            }
        }
        return out
    }

    /// The meeting site an ACTIVE meeting tab's window title belongs to, or
    /// nil for anything else. Teams requires the "Microsoft Teams" marker AND
    /// a meeting/call word so a background chat tab never qualifies; Meet
    /// requires the "Meet – " prefix (en dash or hyphen) so the landing page
    /// ("Google Meet") and unrelated "…meet…" titles never qualify.
    static func meetingSite(forTitle title: String) -> CallSource? {
        let t = title.lowercased()
        if t.contains("microsoft teams"),
           t.contains("meeting") || t.contains("call")
            || t.contains("möte") || t.contains("samtal") {
            return .teams
        }
        if t.hasPrefix("meet – ") || t.hasPrefix("meet - ") {
            return .meet
        }
        return nil
    }
}
