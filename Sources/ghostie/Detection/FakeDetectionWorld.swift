import Foundation
import CoreAudio

/// In-memory fakes for every detection provider protocol — the scripted-fake
/// harness the rearchitecture design promised (Task 1) so a selftest can
/// drive a REAL `DetectionCoordinator` through call lifecycles with no
/// CoreAudio / CoreMediaIO / AX / NSWorkspace. Mutate the fakes' state from
/// the test, then call `notify()` to push a change exactly like the concrete
/// providers do; time is a `VirtualClock` so confirm/grace windows scrub
/// without sleeping (only the coordinator's real 300 ms debounce needs a
/// short wall-clock wait).
///
/// Compiled into the binary like the rest of the selftest support — it is
/// tiny, and `ghostie selftest` must run on any installed copy.
final class FakeDetectionWorld {

    final class Audio: AudioActivityProvider {
        private let lock = NSLock()
        private var handlers: [() -> Void] = []
        private var _procs: [AudioProcessInfo] = []
        var procs: [AudioProcessInfo] {
            get { lock.withLock { _procs } }
            set { lock.withLock { _procs = newValue } }
        }
        func snapshot() -> [AudioProcessInfo] { procs }
        func refresh() {}
        func observe(_ handler: @escaping () -> Void) -> DetectionToken {
            lock.withLock { handlers.append(handler) }
            return DetectionToken {}
        }
        func notify() { lock.withLock { handlers }.forEach { $0() } }
    }

    final class Camera: CameraActivityProvider {
        private let lock = NSLock()
        private var handlers: [() -> Void] = []
        private var _running = false
        var running: Bool {
            get { lock.withLock { _running } }
            set { lock.withLock { _running = newValue } }
        }
        func anyCameraRunning() -> Bool { running }
        func refresh() {}
        func observe(_ handler: @escaping () -> Void) -> DetectionToken {
            lock.withLock { handlers.append(handler) }
            return DetectionToken {}
        }
        func notify() { lock.withLock { handlers }.forEach { $0() } }
    }

    final class Device: DefaultInputDeviceProvider {
        private let lock = NSLock()
        private var handlers: [() -> Void] = []
        private var _deviceId: AudioDeviceID? = 42
        var deviceId: AudioDeviceID? {
            get { lock.withLock { _deviceId } }
            set { lock.withLock { _deviceId = newValue } }
        }
        func currentDeviceId() -> AudioDeviceID? { deviceId }
        func observe(_ handler: @escaping () -> Void) -> DetectionToken {
            lock.withLock { handlers.append(handler) }
            return DetectionToken {}
        }
        func notify() { lock.withLock { handlers }.forEach { $0() } }
    }

    final class Presence: AppPresenceProvider {
        private let lock = NSLock()
        private var handlers: [() -> Void] = []
        private var _apps: [RunningAppInfo] = []
        var apps: [RunningAppInfo] {
            get { lock.withLock { _apps } }
            set { lock.withLock { _apps = newValue } }
        }
        func triggerApps() -> [RunningAppInfo] { apps }
        func observe(_ handler: @escaping () -> Void) -> DetectionToken {
            lock.withLock { handlers.append(handler) }
            return DetectionToken {}
        }
        func notify() { lock.withLock { handlers }.forEach { $0() } }
    }

    final class Tabs: BrowserTabProvider {
        private let lock = NSLock()
        private var _pids: [pid_t] = []
        /// Browser PIDs currently "showing a Teams meeting tab".
        var pids: [pid_t] {
            get { lock.withLock { _pids } }
            set { lock.withLock { _pids = newValue } }
        }
        func pidsWithMeetingTab(browsers: [RunningAppInfo]) -> [pid_t] {
            let eligible = Set(browsers.map(\.pid))
            return pids.filter { eligible.contains($0) }.sorted()
        }
    }

    final class AX: MeetingWindowProvider {
        private let lock = NSLock()
        private var _match: MeetingWindowMatch = .notMatched
        private var _perPid: [pid_t: MeetingWindowMatch] = [:]
        private var _granted = true
        var match: MeetingWindowMatch {
            get { lock.withLock { _match } }
            set { lock.withLock { _match = newValue } }
        }
        /// Per-PID overrides; PIDs not listed fall back to `match`.
        var perPid: [pid_t: MeetingWindowMatch] {
            get { lock.withLock { _perPid } }
            set { lock.withLock { _perPid = newValue } }
        }
        var granted: Bool {
            get { lock.withLock { _granted } }
            set { lock.withLock { _granted = newValue } }
        }
        func hasMeetingWindow(mainAppPid: pid_t, bundleId: String) -> MeetingWindowMatch {
            perPid[mainAppPid] ?? match
        }
        var permissionGranted: Bool { granted }
        @discardableResult
        func promptForPermissionIfNeeded() -> Bool { granted }
    }

    let audio = Audio()
    let camera = Camera()
    let device = Device()
    let presence = Presence()
    let ax = AX()
    let tabs = Tabs()
    let clock = VirtualClock()

    /// A real coordinator wired entirely to the fakes.
    func makeCoordinator(config: Config = Config()) -> DetectionCoordinator {
        DetectionCoordinator(config: config, audio: audio, ax: ax,
                             camera: camera, device: device,
                             presence: presence, tabs: tabs, clock: clock)
    }
}
