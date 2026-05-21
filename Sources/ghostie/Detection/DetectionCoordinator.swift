import Foundation
import CoreAudio
import AppKit

/// Owns the single serial queue on which all detector state is read and
/// written, builds `CallEvidence` from the providers, and drives the state
/// machine. The `start` / `stop` semantics match the legacy `CallDetector` so
/// `Engine.swift` does not change.
///
/// For task 2, only `AudioActivityProvider` is wired with a real
/// implementation. `MeetingWindowProvider` (AX), `CameraActivityProvider`,
/// `DefaultInputDeviceProvider` (with swap quiescence), and
/// `AppPresenceProvider` (push-based) come in tasks 4-7. The state machine
/// already tolerates absent corroborators (AX `.unavailable` plus empty
/// camera) by promoting on input + output alone, which is the dominant real-
/// world case.
final class DetectionCoordinator {

    private let config: Config
    private let queue = DispatchQueue(label: "ghostie.detector")
    private let clock: Clock
    private let stateMachine: CallStateMachine
    private let audio: AudioActivityProvider
    private let ax: MeetingWindowProvider
    private let camera: CameraActivityProvider
    private let device: DefaultInputDeviceProvider
    private let presence: AppPresenceProvider
    private var audioToken: DetectionToken?
    private var cameraToken: DetectionToken?
    private var deviceToken: DetectionToken?
    private var presenceToken: DetectionToken?
    private var backstop: DispatchSourceTimer?
    private var lastDeviceSwapAt: VirtualTime?
    private static let deviceSwapQuiescenceSeconds: TimeInterval = 3
    private var running = false
    /// Lowercased main-app bundle IDs from `config.triggerBundleIds`. The
    /// audio-side filter passes these through `matchesTeamsBundle` which
    /// extends each to also catch `bundle.<helper>` (so Teams helpers
    /// participate in audio attribution) without accidentally cross-matching
    /// (`com.microsoft.teams` does not absorb `com.microsoft.teams2`).
    private let teamsBundleMatchers: [String]

    var onCallStart: ((UUID) -> Void)?
    var onCallStop: ((UUID) -> Void)?

    /// AX prompt is process-wide, not per-coordinator. Engine.applyConfig
    /// recreates the coordinator on every Settings save, and we don't want
    /// to re-open the System Settings deep-link sheet each time. One nudge
    /// per app launch is enough; macOS keeps the user in Settings until they
    /// either grant or close it.
    private static var promptedAXThisSession = false
    private static let promptedAXLock = NSLock()

    init(config: Config,
         audio: AudioActivityProvider = CoreAudioActivityProvider(),
         ax: MeetingWindowProvider = AXMeetingWindowProvider(),
         camera: CameraActivityProvider = CoreMediaIOCameraActivityProvider(),
         device: DefaultInputDeviceProvider = CoreAudioDefaultDeviceProvider(),
         presence: AppPresenceProvider? = nil,
         clock: Clock = SystemClock()) {
        self.config = config
        self.audio = audio
        self.ax = ax
        self.camera = camera
        self.device = device
        self.clock = clock
        self.stateMachine = CallStateMachine(clock: clock)
        let mainIds = config.triggerBundleIds.map { $0.lowercased() }
        self.teamsBundleMatchers = mainIds
        self.presence = presence ?? WorkspaceAppPresenceProvider(triggerBundleIds: mainIds)

        if config.triggerBundlePrefixes != Config().triggerBundlePrefixes {
            Log.warn("config.triggerBundlePrefixes is deprecated and IGNORED. Detection now uses triggerBundleIds (exact match plus 'matcher.<helper>'). Migrate your config.")
        }

        stateMachine.onCallStart = { [weak self] sid in
            guard let self else { return }
            Log.ok("Teams call detected (session \(sid.uuidString.prefix(8))) — starting capture.")
            self.onCallStart?(sid)
        }
        stateMachine.onCallStop = { [weak self] sid in
            guard let self else { return }
            Log.ok("Teams call ended (session \(sid.uuidString.prefix(8))) — finalizing.")
            self.onCallStop?(sid)
        }
        stateMachine.onTransition = { t in
            Log.info("detector \(t.from.rawValue) -> \(t.to.rawValue): \(t.reason) [\(t.evidence.summary)]")
        }
    }

    func start() {
        promptForAXOnceIfNeeded()
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.audioToken = self.audio.observe { [weak self] in
                self?.queue.async { self?.evaluate() }
            }
            self.cameraToken = self.camera.observe { [weak self] in
                self?.queue.async { self?.evaluate() }
            }
            self.deviceToken = self.device.observe { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    self.lastDeviceSwapAt = self.clock.now
                    Log.info("detector: default input device changed; entering \(Int(Self.deviceSwapQuiescenceSeconds))s swap quiescence.")
                    self.evaluate()
                }
            }
            self.presenceToken = self.presence.observe { [weak self] in
                self?.queue.async { self?.evaluate() }
            }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in self?.evaluate() }
            t.resume()
            self.backstop = t
            self.evaluate()
            Log.info("Call detector started (PID-attributed input + output + AX corroborator; camera + device-swap providers pending).")
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            self.running = false
            self.audioToken?.invalidate(); self.audioToken = nil
            self.cameraToken?.invalidate(); self.cameraToken = nil
            self.deviceToken?.invalidate(); self.deviceToken = nil
            self.presenceToken?.invalidate(); self.presenceToken = nil
            self.backstop?.cancel(); self.backstop = nil
            self.stateMachine.forceStop(reason: "detector stopped")
        }
    }

    /// Snapshot of detector state + the current evidence reading. Safe to
    /// call from any thread: provider reads are individually thread-safe
    /// and `lastDeviceSwapAt` is queue-hopped via `queue.sync`.
    struct Snapshot {
        let stage: CallStateMachine.Stage
        let sessionId: UUID?
        let transitionsCount: Int
        let lastTransition: CallStateMachine.Transition?
        let evidence: CallEvidence
    }

    func snapshot() -> Snapshot {
        // Read state-machine fields and `lastDeviceSwapAt` on the detector
        // queue so we can't tear an `Array` mid-append or read an optional
        // `Double` mid-write.
        return queue.sync {
            Snapshot(
                stage: stateMachine.stage,
                sessionId: stateMachine.sessionId,
                transitionsCount: stateMachine.transitions.count,
                lastTransition: stateMachine.transitions.last,
                evidence: buildEvidenceLocked()
            )
        }
    }

    /// Builds a `CallEvidence` snapshot. **Caller must be on `queue`** — this
    /// reads `lastDeviceSwapAt` without locking and is used by `evaluate()`
    /// and `snapshot()` (which both arrange to be on the queue first).
    private func buildEvidenceLocked() -> CallEvidence {
        let mainPids = presence.teamsApps().map(\.pid).sorted()
        let meetingWindow = Self.resolveMeetingWindow(ax: ax, pids: mainPids)
        let cameraPids: [pid_t] = (camera.anyCameraRunning() && !mainPids.isEmpty)
            ? mainPids : []
        let now = clock.now
        let inQuiescence: Bool = {
            guard let t = lastDeviceSwapAt else { return false }
            return (now - t) < Self.deviceSwapQuiescenceSeconds
        }()
        return Self.buildEvidence(
            audio: audio.snapshot(),
            now: now,
            matchers: teamsBundleMatchers,
            defaultDeviceId: device.currentDeviceId(),
            meetingWindow: meetingWindow,
            cameraPids: cameraPids,
            deviceSwapWithinLast3s: inQuiescence
        )
    }

    /// Walk each Teams main PID and return the first matched meeting window.
    /// `.unavailable` propagates only when **every** queried PID was
    /// unavailable; if even one PID was successfully introspected and just
    /// did not match, that's `.notMatched`, not unavailable. (A transient
    /// launching or quitting Teams instance must not poison a clean read.)
    private static func resolveMeetingWindow(ax: MeetingWindowProvider,
                                             pids: [pid_t]) -> MeetingWindowMatch {
        if pids.isEmpty {
            return ax.permissionGranted ? .notMatched
                : .unavailable(reason: "Accessibility permission not granted")
        }
        var sawIntrospectable = false
        var lastUnavailableReason: String?
        for pid in pids {
            switch ax.teamsHasMeetingWindow(mainAppPid: pid) {
            case .matched(let r, let v):
                return .matched(reason: r, heuristicsVersion: v)
            case .notMatched:
                sawIntrospectable = true
            case .unavailable(let r):
                lastUnavailableReason = r
            }
        }
        if sawIntrospectable { return .notMatched }
        return .unavailable(reason: lastUnavailableReason ?? "no introspectable Teams app")
    }

    // Note: deliberately no public `stage` / `sessionId` / `transitions`
    // accessors. Callers want a coherent snapshot, not three reads racing
    // each other against `evaluate()` on the detector queue. Use `snapshot()`.

    private func promptForAXOnceIfNeeded() {
        Self.promptedAXLock.lock()
        let alreadyPrompted = Self.promptedAXThisSession
        Self.promptedAXThisSession = true
        Self.promptedAXLock.unlock()
        if alreadyPrompted { return }
        _ = ax.promptForPermissionIfNeeded()
        if !ax.permissionGranted {
            Log.warn("Accessibility permission not granted — call detection runs without the AX corroborator.")
            Log.warn("Grant in System Settings ▸ Privacy & Security ▸ Accessibility to add a third signal.")
        }
    }

    // MARK: - Internals

    private func evaluate() {
        // Caller is always on `queue` (listener callbacks marshal here, the
        // backstop timer fires on this queue, start()/stop() dispatch here).
        let evidence = buildEvidenceLocked()
        stateMachine.evaluate(evidence: evidence)
    }

    /// Pure transform from raw provider output to a `CallEvidence` snapshot.
    /// Kept static + injectable so future selftests can exercise the filter
    /// without spinning up CoreAudio listeners.
    /// Single source of truth for "does this bundle id belong to Teams?".
    /// Exact match or `matcher.<helper>`. Prevents `com.microsoft.teams` from
    /// accidentally matching `com.microsoft.teams2` (which the pure-prefix
    /// form would). Used both by the audio-side filter here and by `doctor`.
    static func matchesTeamsBundle(_ bundleId: String, matchers: [String]) -> Bool {
        let b = bundleId.lowercased()
        return matchers.contains(where: { b == $0 || b.hasPrefix($0 + ".") })
    }

    static func buildEvidence(audio: [AudioProcessInfo],
                              now: VirtualTime,
                              matchers: [String],
                              defaultDeviceId: AudioDeviceID?,
                              meetingWindow: MeetingWindowMatch,
                              cameraPids: [pid_t],
                              deviceSwapWithinLast3s: Bool) -> CallEvidence {
        let teamsProcs = audio.filter { p in
            guard let b = p.bundleId?.lowercased() else { return false }
            return matchesTeamsBundle(b, matchers: matchers)
        }
        let inputPids = teamsProcs.filter(\.isRunningInput).map(\.pid)
        let outputPids = teamsProcs.filter(\.isRunningOutput).map(\.pid)
        let allTeamsPids = Array(Set(teamsProcs.map(\.pid))).sorted()
        return CallEvidence(
            timestamp: now,
            teamsMainPids: allTeamsPids,
            teamsInputPids: inputPids.sorted(),
            teamsOutputPids: outputPids.sorted(),
            teamsCameraPids: cameraPids.sorted(),
            meetingWindow: meetingWindow,
            defaultInputDeviceId: defaultDeviceId,
            deviceSwapWithinLast3s: deviceSwapWithinLast3s
        )
    }
}
