import Foundation
import CoreAudio

// MARK: - Provider protocols
//
// Each protocol has a snapshot accessor (cheap synchronous read) and an
// `observe` method that pushes changes via a closure. Concrete implementations
// register CoreAudio / CoreMediaIO / AX / NSWorkspace listeners; fakes for
// selftest implement the same surface against in-memory state. The state
// machine never touches a provider implementation directly.

/// Per-process audio I/O attribution. Backed by
/// `kAudioHardwarePropertyProcessObjectList` +
/// `kAudioProcessPropertyIsRunningInput` / `IsRunningOutput` (macOS 14.2+).
protocol AudioActivityProvider: AnyObject {
    func snapshot() -> [AudioProcessInfo]
    /// Authoritative rebuild of any internally cached state from a fresh
    /// system read. The coordinator's periodic backstop calls this before
    /// evaluating, so a missed push notification heals within one period.
    func refresh()
    func observe(_ handler: @escaping () -> Void) -> DetectionToken
}

/// Whether any camera on the system is currently in use. Public macOS
/// CoreMediaIO does not expose per-process camera attribution (unlike modern
/// CoreAudio), so the coordinator approximates Teams camera use as "any
/// camera in use AND Teams main app running" — a weaker signal than audio
/// attribution but still useful as a corroborator for video calls.
protocol CameraActivityProvider: AnyObject {
    func anyCameraRunning() -> Bool
    /// Authoritative rebuild of any internally cached state from a fresh
    /// system read (see `AudioActivityProvider.refresh`).
    func refresh()
    func observe(_ handler: @escaping () -> Void) -> DetectionToken
}

/// System default input device. The state machine uses changes here to start
/// a 3 s quiescence pulse during which `primarySignal=false` does not advance
/// toward `ending`.
protocol DefaultInputDeviceProvider: AnyObject {
    func currentDeviceId() -> AudioDeviceID?
    func observe(_ handler: @escaping () -> Void) -> DetectionToken
}

/// Which Teams (or browser, if browser mode is on) apps are currently
/// running. Push-based via NSWorkspace launch/terminate notifications. The
/// observe callback fires on app launch/terminate; the coordinator re-reads
/// `triggerApps()` rather than consuming a payload, so the closure takes none.
protocol AppPresenceProvider: AnyObject {
    func triggerApps() -> [RunningAppInfo]
    func observe(_ handler: @escaping () -> Void) -> DetectionToken
}

/// Which of the given browser main-app PIDs currently show a Teams meeting
/// tab (AX window-title probe). Pull-based, queried only when browser
/// detection is enabled AND there's a reason to look (browser input I/O or
/// an already-active session) — same cost philosophy as the meeting-window
/// gate. Returning a PID makes that browser's mic use eligible as a primary
/// signal; ordinary web-mic use in a tab that isn't a Teams meeting never
/// qualifies.
protocol BrowserTabProvider: AnyObject {
    func pidsWithMeetingTab(browsers: [RunningAppInfo]) -> [pid_t]
}

/// AX-based meeting-window probe scoped to a single main-app PID. The
/// coordinator queries this pull-style on every evaluate; permission state is
/// re-checked on the same path. `bundleId` selects the per-app heuristics
/// rule set (Teams vs Zoom title shapes).
protocol MeetingWindowProvider: AnyObject {
    func hasMeetingWindow(mainAppPid: pid_t, bundleId: String) -> MeetingWindowMatch

    var permissionGranted: Bool { get }
    /// Trigger the standard system AX prompt the first time the detector
    /// starts. Idempotent: no-op when already granted, no-op for providers
    /// that don't need a prompt.
    @discardableResult
    func promptForPermissionIfNeeded() -> Bool
}
