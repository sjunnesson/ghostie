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
final class CoreMediaIOCameraActivityProvider: CameraActivityProvider {

    private let listenerQueue = DispatchQueue(label: "ghostie.coremediaio.listener")
    private let stateLock = NSLock()
    private let fanout = ChangeFanout()
    private var perDeviceTeardowns: [CMIOObjectID: () -> Void] = [:]
    private var deviceListTeardown: (() -> Void)?

    init() {
        installDeviceListListener()
        reconcileDeviceListeners()
    }

    deinit {
        // Drain any in-flight CoreMediaIO callback before tearing down (a
        // listener block could be partway through `reconcileDeviceListeners`
        // when the last strong ref drops).
        listenerQueue.sync { }
        deviceListTeardown?()
        for (_, tear) in perDeviceTeardowns { tear() }
    }

    func anyCameraRunning() -> Bool {
        let devices = Self.fetchDevices()
        for d in devices where Self.isRunningSomewhere(d) { return true }
        return false
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

    private func reconcileDeviceListeners() {
        let current = Set(Self.fetchDevices())
        stateLock.lock()
        let known = Set(perDeviceTeardowns.keys)
        let added = current.subtracting(known)
        let removed = known.subtracting(current)
        for d in removed {
            perDeviceTeardowns.removeValue(forKey: d)?()
        }
        stateLock.unlock()
        for d in added {
            installRunningListener(d)
        }
    }

    private func installRunningListener(_ device: CMIOObjectID) {
        let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
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
