import Foundation
import AppKit

/// Push-based `AppPresenceProvider` over NSWorkspace launch/terminate
/// notifications. Maintains an internal cache so `teamsApps()` is a synchronous
/// read with no enumeration cost on the hot path.
///
/// Exact bundle-ID match: helper PIDs are excluded from this provider's
/// output because the coordinator only queries main apps for AX. Helper-
/// process audio is still picked up by the audio activity provider via its
/// own prefix-with-dot match.
final class WorkspaceAppPresenceProvider: AppPresenceProvider {

    private let workspace = NSWorkspace.shared
    private let center = NSWorkspace.shared.notificationCenter
    private let stateLock = NSLock()
    private var observerTokens: [NSObjectProtocol] = []
    private var cache: [pid_t: RunningAppInfo] = [:]
    private let fanout = ChangeFanout()
    private let triggerBundleIds: Set<String>

    init(triggerBundleIds: [String]) {
        self.triggerBundleIds = Set(triggerBundleIds.map { $0.lowercased() })
        rebuildCache()
        let launch = center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.handleAppChange() }
        let terminate = center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: nil
        ) { [weak self] _ in self?.handleAppChange() }
        observerTokens = [launch, terminate]
    }

    deinit {
        for o in observerTokens { center.removeObserver(o) }
    }

    func teamsApps() -> [RunningAppInfo] {
        stateLock.lock(); defer { stateLock.unlock() }
        return cache.values
            .filter { triggerBundleIds.contains($0.bundleId.lowercased()) }
            .sorted { $0.pid < $1.pid }
    }

    func observe(_ handler: @escaping () -> Void) -> DetectionToken {
        fanout.subscribe(handler)
    }

    // MARK: - Internals

    private func handleAppChange() {
        rebuildCache()
        fanout.notify()
    }

    private func rebuildCache() {
        var next: [pid_t: RunningAppInfo] = [:]
        for app in workspace.runningApplications {
            guard let bid = app.bundleIdentifier else { continue }
            next[app.processIdentifier] = RunningAppInfo(
                pid: app.processIdentifier, bundleId: bid)
        }
        stateLock.lock()
        cache = next
        stateLock.unlock()
    }
}
