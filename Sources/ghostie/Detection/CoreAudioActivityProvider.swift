import Foundation
import CoreAudio
import AppKit

/// Concrete `AudioActivityProvider` against the macOS 14.2+ public CoreAudio
/// per-process I/O properties:
///
///   - `kAudioHardwarePropertyProcessObjectList`
///   - `kAudioProcessPropertyPID`
///   - `kAudioProcessPropertyIsRunningInput`
///   - `kAudioProcessPropertyIsRunningOutput`
///
/// Bundle ID is resolved via `NSRunningApplication(processIdentifier:)`, which
/// gives a stable identifier for live processes and `nil` for transient ones
/// (we filter those out at the coordinator). Listeners are registered on the
/// hardware object list and on each per-process IsRunningInput/Output property;
/// adds and removes are reconciled when the process list changes. All
/// listeners are torn down on dealloc.
final class CoreAudioActivityProvider: AudioActivityProvider {

    private let listenerQueue = DispatchQueue(label: "ghostie.coreaudio.listener")
    private let stateLock = NSLock()
    private let fanout = ChangeFanout()
    private var perProcessTeardowns: [AudioObjectID: () -> Void] = [:]
    private var listListenerTeardown: (() -> Void)?

    init() {
        installListListener()
        reconcileProcessListeners()
    }

    deinit {
        // Drain any in-flight callback before touching the teardowns:
        // a CoreAudio block can be partway through `reconcileProcessListeners`
        // when the last strong ref drops. Synchronizing on listenerQueue
        // ensures it finishes before we yank the listeners.
        listenerQueue.sync { }
        listListenerTeardown?()
        for (_, tear) in perProcessTeardowns { tear() }
    }

    func snapshot() -> [AudioProcessInfo] {
        Self.fetchProcessObjects()
            .compactMap { Self.buildInfo(processObject: $0) }
    }

    func observe(_ handler: @escaping () -> Void) -> DetectionToken {
        fanout.subscribe(handler)
    }

    // MARK: - Internals

    private func installListListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reconcileProcessListeners()
            self?.notify()
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let queue = listenerQueue
        let s = AudioObjectAddPropertyListenerBlock(sys, &address, queue, block)
        guard s == noErr else {
            Log.warn("CoreAudio process-object-list listener failed: OSStatus \(s)")
            return
        }
        listListenerTeardown = { [block, queue] in
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyProcessObjectList,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(sys, &a, queue, block)
        }
    }

    private func reconcileProcessListeners() {
        let current = Set(Self.fetchProcessObjects())
        stateLock.lock()
        let known = Set(perProcessTeardowns.keys)
        let added = current.subtracting(known)
        let removed = known.subtracting(current)
        for obj in removed {
            perProcessTeardowns.removeValue(forKey: obj)?()
        }
        stateLock.unlock()
        for obj in added {
            installPerProcessListeners(obj)
        }
    }

    private func installPerProcessListeners(_ obj: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notify()
        }
        var inputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var outputAddr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let queue = listenerQueue
        let s1 = AudioObjectAddPropertyListenerBlock(obj, &inputAddr, queue, block)
        let s2 = AudioObjectAddPropertyListenerBlock(obj, &outputAddr, queue, block)
        // Either or both may legitimately fail (e.g. a process that does not
        // expose those properties); we still want a teardown for whichever
        // succeeded.
        let tear: () -> Void = { [block, queue] in
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var b = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            if s1 == noErr {
                _ = AudioObjectRemovePropertyListenerBlock(obj, &a, queue, block)
            }
            if s2 == noErr {
                _ = AudioObjectRemovePropertyListenerBlock(obj, &b, queue, block)
            }
        }
        stateLock.lock()
        perProcessTeardowns[obj] = tear
        stateLock.unlock()
    }

    private func notify() { fanout.notify() }

    // MARK: - Static reads

    private static func fetchProcessObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var ids = [AudioObjectID](repeating: 0, count: count)
        let status = ids.withUnsafeMutableBufferPointer { buf -> OSStatus in
            guard let base = buf.baseAddress else { return -1 }
            return AudioObjectGetPropertyData(sys, &address, 0, nil, &size, base)
        }
        guard status == noErr else { return [] }
        return ids
    }

    private static func buildInfo(processObject: AudioObjectID) -> AudioProcessInfo? {
        let pid = fetchPID(processObject)
        guard pid > 0 else { return nil }
        let bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        let input = fetchUInt32(processObject, kAudioProcessPropertyIsRunningInput) != 0
        let output = fetchUInt32(processObject, kAudioProcessPropertyIsRunningOutput) != 0
        return AudioProcessInfo(pid: pid, bundleId: bundle,
                                isRunningInput: input, isRunningOutput: output)
    }

    private static func fetchPID(_ obj: AudioObjectID) -> pid_t {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &pid)
        return status == noErr ? pid : 0
    }

    private static func fetchUInt32(_ obj: AudioObjectID,
                                    _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(obj, &address, 0, nil, &size, &value)
        return status == noErr ? value : 0
    }

    // MARK: - Public statics (used by doctor + diagnose-detect)

    /// System default input device id (or nil if none). Used by the doctor
    /// command's existing health check; the production detector uses
    /// `CoreAudioDefaultDeviceProvider` instead.
    static func defaultInputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        guard status == noErr, device != 0 else { return nil }
        return device
    }
}
