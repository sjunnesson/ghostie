import Foundation
import CoreMediaIO

/// Public CoreMediaIO does not give us per-process camera attribution the way
/// modern CoreAudio does (`kAudioProcessPropertyIsRunningInput`). What it
/// does give us, since Catalina, is `kCMIODevicePropertyDeviceIsRunningSomewhere`
/// per camera device. We enumerate devices, observe that flag, and the
/// coordinator approximates "Teams using the camera" as
/// "any camera running AND Teams main app running".
///
/// That approximation is fine for our purposes: this is a *corroborator*, not
/// a veto. A user with Teams open who turns on the camera in Zoom would be a
/// false positive — but they would also need to be holding the mic via Teams
/// (the primary signal), which Zoom would not allow. The combination is
/// vanishingly unlikely in practice.
///
/// `anyCameraRunning()` is a cheap read of a cached per-device running map:
/// the push listener on `DeviceIsRunningSomewhere` patches its device's entry,
/// list changes rebuild the map, and `refresh()` (the coordinator's 5 s
/// backstop) re-reads every device authoritatively so a missed CMIO
/// notification can never go stale for more than one period. Reconciliation
/// is serialized on `listenerQueue`; the map is lock-guarded for cross-queue
/// reads.
final class CoreMediaIOCameraActivityProvider: CameraActivityProvider {

    private let listenerQueue = DispatchQueue(label: "ghostie.coremediaio.listener")
    private let stateLock = NSLock()
    private let fanout = ChangeFanout()
    private var perDeviceTeardowns: [CMIOObjectID: () -> Void] = [:]
    /// Cached `DeviceIsRunningSomewhere` per known camera device.
    private var runningByDevice: [CMIOObjectID: Bool] = [:]
    private var deviceListTeardown: (() -> Void)?

    init() {
        installDeviceListListener()
        // Serialize the initial build with any list callback already in
        // flight on listenerQueue.
        listenerQueue.sync { self.reconcileDeviceListeners() }
    }

    deinit {
        // Drain any in-flight CoreMediaIO callback before tearing down (a
        // listener block could be partway through `reconcileDeviceListeners`
        // when the last strong ref drops).
        listenerQueue.sync { }
        deviceListTeardown?()
        for (_, tear) in perDeviceTeardowns { tear() }
    }

    /// Cheap cached read — no CMIO calls on this path.
    func anyCameraRunning() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return runningByDevice.values.contains(true)
    }

    /// Authoritative rebuild: re-enumerates devices and re-reads every
    /// device's running flag. Called by the coordinator's periodic backstop.
    /// Must not be called from `listenerQueue` (it hops onto it with `sync`).
    func refresh() {
        listenerQueue.sync { self.reconcileDeviceListeners() }
    }

    func observe(_ handler: @escaping () -> Void) -> DetectionToken {
        fanout.subscribe(handler)
    }

    // MARK: - Internals

    private func installDeviceListListener() {
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reconcileDeviceListeners()
            self?.notify()
        }
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let sys = CMIOObjectID(kCMIOObjectSystemObject)
        let queue = listenerQueue
        let status = CMIOObjectAddPropertyListenerBlock(sys, &address, queue, block)
        guard status == kCMIOHardwareNoError else {
            Log.warn("CoreMediaIO device-list listener failed: status \(status)")
            return
        }
        deviceListTeardown = { [block, queue] in
            var a = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            _ = CMIOObjectRemovePropertyListenerBlock(sys, &a, queue, block)
        }
    }

    /// Caller must be on `listenerQueue` (CMIO list callback, `refresh()`, or
    /// `init`'s sync hop). Always rebuilds the whole running map from a fresh
    /// per-device read — camera counts are tiny (typically 1-3), so the full
    /// authoritative read costs nothing and keeps the cache trivially correct.
    private func reconcileDeviceListeners() {
        let current = Set(Self.fetchDevices())
        var fresh: [CMIOObjectID: Bool] = [:]
        for d in current { fresh[d] = Self.isRunningSomewhere(d) }

        stateLock.lock()
        let known = Set(perDeviceTeardowns.keys)
        let added = current.subtracting(known)
        var teardowns: [() -> Void] = []
        for d in known.subtracting(current) {
            if let t = perDeviceTeardowns.removeValue(forKey: d) { teardowns.append(t) }
        }
        runningByDevice = fresh
        stateLock.unlock()
        for t in teardowns { t() }
        for d in added {
            installRunningListener(d)
        }
    }

    private func installRunningListener(_ device: CMIOObjectID) {
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.updateRunning(device)
            self?.notify()
        }
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let queue = listenerQueue
        let status = CMIOObjectAddPropertyListenerBlock(device, &address, queue, block)
        let tear: () -> Void = { [block, queue] in
            var a = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            if status == kCMIOHardwareNoError {
                _ = CMIOObjectRemovePropertyListenerBlock(device, &a, queue, block)
            }
        }
        stateLock.lock()
        perDeviceTeardowns[device] = tear
        stateLock.unlock()
    }

    /// Push listener fired for one device: re-read just that device's flag
    /// and patch the cache. Ignores devices already dropped from the map (a
    /// late callback racing a list-change removal).
    private func updateRunning(_ device: CMIOObjectID) {
        let running = Self.isRunningSomewhere(device)
        stateLock.lock()
        if runningByDevice[device] != nil {
            runningByDevice[device] = running
        }
        stateLock.unlock()
    }

    private func notify() { fanout.notify() }

    // MARK: - Static reads

    private static func fetchDevices() -> [CMIOObjectID] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let sys = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(sys, &address, 0, nil, &size) == kCMIOHardwareNoError,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<CMIOObjectID>.size
        var ids = [CMIOObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            guard let base = buf.baseAddress else { return -1 }
            var dataUsed: UInt32 = size
            return CMIOObjectGetPropertyData(sys, &address, 0, nil, size, &dataUsed, base)
        }
        guard status == kCMIOHardwareNoError else { return [] }
        return ids
    }

    private static func isRunningSomewhere(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var running: UInt32 = 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        var dataUsed: UInt32 = 0
        let status = CMIOObjectGetPropertyData(device, &address, 0, nil, size, &dataUsed, &running)
        return status == kCMIOHardwareNoError && running != 0
    }
}
