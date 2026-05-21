import Foundation

/// Tiny thread-safe many-handler fanout shared by the four push-based
/// providers (`CoreAudioActivityProvider`, `CoreMediaIOCameraActivityProvider`,
/// `CoreAudioDefaultDeviceProvider`, `WorkspaceAppPresenceProvider`). Each
/// provider used to open-code the same `UUID -> () -> Void` dictionary plus a
/// lock plus a `notify()` snapshot dance; pulled out here so the
/// provider-specific code is only the listener registration.
final class ChangeFanout {

    private let lock = NSLock()
    private var handlers: [UUID: () -> Void] = [:]

    func subscribe(_ handler: @escaping () -> Void) -> DetectionToken {
        let id = UUID()
        lock.lock()
        handlers[id] = handler
        lock.unlock()
        return DetectionToken { [weak self] in
            self?.lock.lock()
            self?.handlers.removeValue(forKey: id)
            self?.lock.unlock()
        }
    }

    /// Snapshot under the lock, fire outside it. Same pattern as the
    /// original open-coded notify methods.
    func notify() {
        lock.lock()
        let snap = Array(handlers.values)
        lock.unlock()
        for h in snap { h() }
    }
}
