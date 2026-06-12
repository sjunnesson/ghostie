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
/// gives a stable identifier for live processes and `nil` for transient ones.
///
/// Cost model: the process-LIST listener stays unscoped (it must fire when a
/// new Teams helper launches), but per-process IsRunningInput/Output listeners
/// are installed **only** on processes whose bundle ID matches the injected
/// Teams matchers (`DetectionCoordinator.matchesTeamsBundle` semantics: exact
/// or `matcher.<helper>`). Spotify starting playback therefore fires nothing.
///
/// `snapshot()` is a cheap read of an incrementally-maintained cache:
///   - per-process listeners update the matching process's I/O flags in place;
///   - list changes reconcile listeners + cache for added/removed objects;
///   - `refresh()` (called by the coordinator's 5 s backstop) is the
///     authoritative full rebuild — it re-resolves every object's bundle ID,
///     which also heals the "helper's audio object appeared before
///     NSRunningApplication knew its bundle ID" race.
///
/// All reconciliation runs serialized on `listenerQueue` (CoreAudio delivers
/// the listener blocks there; `refresh()` and `init` hop onto it with `sync`),
/// so listener install/teardown can never race itself. The cache dictionaries
/// are additionally guarded by `stateLock` because `snapshot()` reads from the
/// coordinator's queue. All listeners are torn down on dealloc.
final class CoreAudioActivityProvider: AudioActivityProvider {

    private let listenerQueue = DispatchQueue(label: "ghostie.coreaudio.listener")
    private let stateLock = NSLock()
    private let fanout = ChangeFanout()
    /// Lowercased Teams main-app bundle IDs (same list the coordinator feeds
    /// `matchesTeamsBundle`, so helpers count too).
    private let matchers: [String]
    private var perProcessTeardowns: [AudioObjectID: () -> Void] = [:]
    /// The incrementally-maintained snapshot: one entry per *matching* audio
    /// process object. Non-matching processes never appear here (the
    /// coordinator's evidence filter would drop them anyway).
    private var cache: [AudioObjectID: AudioProcessInfo] = [:]
    /// Objects examined and found non-matching (foreign bundle, no bundle,
    /// or no PID). Skipped on incremental reconciles so a list change does
    /// not re-resolve every process on the system; re-examined on `refresh()`.
    private var nonMatching: Set<AudioObjectID> = []
    private var listListenerTeardown: (() -> Void)?

    /// - Parameter matchers: lowercased trigger bundle IDs; a process counts
    ///   when its bundle ID is an exact match or `<matcher>.<suffix>`.
    init(matchers: [String]) {
        self.matchers = matchers.map { $0.lowercased() }
        installListListener()
        // Serialize the initial build with any list callback that may already
        // be in flight on listenerQueue.
        listenerQueue.sync { self.reconcileProcessListeners(reexamineAll: true) }
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

    /// Cheap cached read — no CoreAudio calls on this path.
    func snapshot() -> [AudioProcessInfo] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(cache.values)
    }

    /// Authoritative full rebuild: re-fetches the process object list and
    /// re-resolves bundle IDs + I/O flags for every object, installing or
    /// tearing down listeners as needed. The coordinator's periodic backstop
    /// calls this so any missed notification heals within one period.
    /// Must not be called from `listenerQueue` (it hops onto it with `sync`).
    func refresh() {
        listenerQueue.sync { self.reconcileProcessListeners(reexamineAll: true) }
    }

    func observe(_ handler: @escaping () -> Void) -> DetectionToken {
        fanout.subscribe(handler)
    }

    // MARK: - Internals

    private func installListListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.reconcileProcessListeners(reexamineAll: false)
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

    /// Caller must be on `listenerQueue` (CoreAudio list callback, `refresh()`,
    /// or `init`'s sync hop) so two reconciles can never interleave.
    ///
    /// - Parameter reexamineAll: `false` for incremental list changes (only
    ///   genuinely-new objects get a bundle lookup); `true` for the
    ///   authoritative rebuild (every object is re-resolved, healing stale
    ///   flags and late bundle-ID registration for fresh helpers).
    private func reconcileProcessListeners(reexamineAll: Bool) {
        let current = Set(Self.fetchProcessObjects())

        // Drop state for objects that left the system.
        stateLock.lock()
        var teardowns: [() -> Void] = []
        for obj in Set(perProcessTeardowns.keys).subtracting(current) {
            if let t = perProcessTeardowns.removeValue(forKey: obj) { teardowns.append(t) }
            cache.removeValue(forKey: obj)
        }
        nonMatching.formIntersection(current)
        let listening = Set(perProcessTeardowns.keys)
        let skip = nonMatching
        stateLock.unlock()
        for t in teardowns { t() }

        let toExamine = reexamineAll
            ? current
            : current.subtracting(listening).subtracting(skip)
        for obj in toExamine {
            examine(obj, hasListeners: listening.contains(obj))
        }
    }

    /// Resolve one process object: matching processes get a cache entry and
    /// (if missing) per-object listeners; everything else is remembered in
    /// `nonMatching` until the next full refresh. Caller on `listenerQueue`.
    private func examine(_ obj: AudioObjectID, hasListeners: Bool) {
        if let info = Self.buildInfo(processObject: obj),
           let bundle = info.bundleId,
           DetectionCoordinator.matchesTeamsBundle(bundle, matchers: matchers) {
            stateLock.lock()
            cache[obj] = info
            nonMatching.remove(obj)
            stateLock.unlock()
            // A flag flip between the buildInfo read above and the listener
            // install below could be missed; the 5 s backstop refresh heals it.
            if !hasListeners { installPerProcessListeners(obj) }
        } else {
            // Non-matching, transient (no PID), or bundle not yet resolvable.
            // Ensure no listener or cache entry survives a full refresh that
            // demoted it, and skip it on incremental reconciles.
            stateLock.lock()
            let tear = perProcessTeardowns.removeValue(forKey: obj)
            cache.removeValue(forKey: obj)
            nonMatching.insert(obj)
            stateLock.unlock()
            tear?()
        }
    }

    private func installPerProcessListeners(_ obj: AudioObjectID) {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.updateRunningFlags(obj)
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

    /// Per-process listener fired: re-read just this object's two flags and
    /// patch the cache entry in place (PID/bundle are immutable for a live
    /// process object).
    private func updateRunningFlags(_ obj: AudioObjectID) {
        let input = Self.fetchUInt32(obj, kAudioProcessPropertyIsRunningInput) != 0
        let output = Self.fetchUInt32(obj, kAudioProcessPropertyIsRunningOutput) != 0
        stateLock.lock()
        if let old = cache[obj] {
            cache[obj] = AudioProcessInfo(pid: old.pid, bundleId: old.bundleId,
                                          isRunningInput: input,
                                          isRunningOutput: output)
        }
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
