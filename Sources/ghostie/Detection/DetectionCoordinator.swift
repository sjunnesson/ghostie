import Foundation
import CoreAudio
import AppKit

/// Owns the single serial queue on which all detector state is read and
/// written, builds `CallEvidence` from the providers, and drives the state
/// machine. The `start` / `stop` semantics match the legacy `CallDetector` so
/// `Engine.swift` does not change.
///
/// All five providers are live: `CoreAudioActivityProvider` (per-PID
/// input/output I/O), `AXMeetingWindowProvider`, `CoreMediaIOCameraActivityProvider`,
/// `CoreAudioDefaultDeviceProvider` (swap quiescence), and
/// `WorkspaceAppPresenceProvider`. The state machine tolerates absent
/// corroborators (AX `.unavailable` plus empty camera) by promoting on
/// input + output alone, which is the dominant real-world case.
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
    /// True while a debounced `evaluate()` is scheduled (see
    /// `scheduleEvaluate()`). Only touched on `queue`.
    private var evaluatePending = false
    private static let changeDebounceSeconds: TimeInterval = 0.3
    private var running = false
    /// Lowercased main-app bundle IDs from `config.triggerBundleIds`. The
    /// audio-side filter passes these through `matchesTriggerBundle` which
    /// extends each to also catch `bundle.<helper>` (so Teams helpers
    /// participate in audio attribution) without accidentally cross-matching
    /// (`com.microsoft.teams` does not absorb `com.microsoft.teams2`).
    private let triggerBundleMatchers: [String]
    /// Lowercased browser bundle IDs eligible for the Teams-tab probe.
    /// Empty when `detectBrowserTeams` is off — every browser branch in
    /// `buildEvidenceLocked` then short-circuits.
    private let browserMatchers: [String]
    private let tabs: BrowserTabProvider

    var onCallStart: ((UUID) -> Void)?
    var onCallStop: ((UUID) -> Void)?
    var onTentativeStart: ((UUID) -> Void)?
    var onTentativeDiscard: ((UUID) -> Void)?

    /// AX prompt is process-wide, not per-coordinator. Engine.applyConfig
    /// recreates the coordinator on every Settings save, and we don't want
    /// to re-open the System Settings deep-link sheet each time. One nudge
    /// per app launch is enough; macOS keeps the user in Settings until they
    /// either grant or close it.
    private static var promptedAXThisSession = false
    private static let promptedAXLock = NSLock()

    /// `audio` defaults to a `CoreAudioActivityProvider` scoped to the config's
    /// trigger bundle IDs (it needs the matcher list to avoid installing
    /// per-process CoreAudio listeners on every audio process on the system),
    /// hence the optional-with-nil default rather than a default expression.
    init(config: Config,
         audio: AudioActivityProvider? = nil,
         ax: MeetingWindowProvider = AXMeetingWindowProvider(),
         camera: CameraActivityProvider = CoreMediaIOCameraActivityProvider(),
         device: DefaultInputDeviceProvider = CoreAudioDefaultDeviceProvider(),
         presence: AppPresenceProvider? = nil,
         tabs: BrowserTabProvider = AXBrowserTabProvider(),
         clock: Clock = SystemClock()) {
        let mainIds = config.triggerBundleIds.map { $0.lowercased() }
        // Browser-Teams is opt-in: with it off the browser matcher list is
        // empty and browsers never get CoreAudio listeners, presence
        // tracking, or AX tab probes.
        let browserIds = config.detectBrowserTeams
            ? config.browserBundleIds.map { $0.lowercased() } : []
        self.config = config
        self.audio = audio ?? CoreAudioActivityProvider(matchers: mainIds + browserIds)
        self.ax = ax
        self.camera = camera
        self.device = device
        self.tabs = tabs
        self.clock = clock
        var smConfig = CallStateMachine.Config()
        smConfig.endGraceSeconds = config.endGraceSeconds
        self.stateMachine = CallStateMachine(config: smConfig, clock: clock)
        self.triggerBundleMatchers = mainIds
        self.browserMatchers = browserIds
        self.presence = presence
            ?? WorkspaceAppPresenceProvider(triggerBundleIds: mainIds + browserIds)

        if config.triggerBundlePrefixes != Config().triggerBundlePrefixes {
            Log.warn("config.triggerBundlePrefixes is deprecated and IGNORED. Detection now uses triggerBundleIds (exact match plus 'matcher.<helper>'). Migrate your config.")
        }

        stateMachine.onCallStart = { [weak self] sid in
            guard let self else { return }
            Log.ok("Call detected (session \(sid.uuidString.prefix(8))) — starting capture.")
            self.onCallStart?(sid)
        }
        stateMachine.onCallStop = { [weak self] sid in
            guard let self else { return }
            Log.ok("Call ended (session \(sid.uuidString.prefix(8))) — finalizing.")
            self.onCallStop?(sid)
        }
        stateMachine.onTentativeStart = { [weak self] sid in
            guard let self else { return }
            Log.info("Possible call (session \(sid.uuidString.prefix(8))) — tentative capture started.")
            self.onTentativeStart?(sid)
        }
        stateMachine.onTentativeDiscard = { [weak self] sid in
            guard let self else { return }
            Log.info("Candidate never confirmed (session \(sid.uuidString.prefix(8))) — tentative capture discarded.")
            self.onTentativeDiscard?(sid)
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
                self?.queue.async { self?.scheduleEvaluate() }
            }
            self.cameraToken = self.camera.observe { [weak self] in
                self?.queue.async { self?.scheduleEvaluate() }
            }
            self.deviceToken = self.device.observe { [weak self] in
                self?.queue.async {
                    guard let self else { return }
                    // Record the swap timestamp immediately so the 3 s
                    // quiescence window runs from notification arrival, not
                    // from the debounced evaluate ~300 ms later.
                    self.lastDeviceSwapAt = self.clock.now
                    Log.info("detector: audio device topology changed; entering \(Int(Self.deviceSwapQuiescenceSeconds))s swap quiescence.")
                    self.scheduleEvaluate()
                }
            }
            self.presenceToken = self.presence.observe { [weak self] in
                self?.queue.async { self?.scheduleEvaluate() }
            }
            let t = DispatchSource.makeTimerSource(queue: self.queue)
            t.schedule(deadline: .now() + 5, repeating: 5)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                // The audio/camera providers serve incrementally-maintained
                // caches between push events; the backstop is the staleness
                // safety net, so force an authoritative rebuild before reading.
                self.audio.refresh()
                self.camera.refresh()
                self.evaluate()
            }
            t.resume()
            self.backstop = t
            self.evaluate()
            Log.info("Call detector started (PID-attributed input + output; AX, camera and device-swap corroborators live).")
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
        let allApps = presence.triggerApps().sorted { $0.pid < $1.pid }
        // Browsers only ever qualify through the tab probe; native trigger
        // apps (Teams, Zoom) qualify by bundle alone.
        let nativeApps = allApps.filter {
            !browserMatchers.contains($0.bundleId.lowercased())
        }
        let audioProcs = audio.snapshot()
        // AX gate: the meeting-window walk is synchronous IPC into the Teams
        // Electron process, and the state machine consults AX purely as a
        // corroborator — it can only influence promotion when a primary
        // signal (Teams mic input) exists or the machine is already past
        // idle. In the dominant "Teams open all day, no call" case
        // (idle + no Teams input I/O) skip the walk entirely and report the
        // corroborator as honestly unqueried (`.unavailable`, which the state
        // machine treats identically to `.notMatched`: no "ax" corroborator).
        // The gate cannot starve confirmation: it reads the *same* fresh
        // audio snapshot this evidence is built from, so the evaluate that
        // first observes primary already re-queries AX. Reading
        // `stateMachine.stage` here is safe — the machine is only mutated on
        // `queue` (evaluate/forceStop) and this method requires `queue` too.
        let primaryNativeAudio = audioProcs.contains { p in
            guard let b = p.bundleId else { return false }
            return p.isRunningInput
                && Self.matchesTriggerBundle(b, matchers: triggerBundleMatchers)
        }
        // Browser-Teams (opt-in): the tab probe runs under the same cost
        // gate as the meeting-window walk — only when a browser is actually
        // using the mic (or a session is already past idle) do we pay the
        // AX title read. A browser PID is then eligible as primary only
        // while one of its windows shows a Teams meeting tab.
        var browserTabPids: [pid_t] = []
        if !browserMatchers.isEmpty {
            let browserApps = allApps.filter {
                browserMatchers.contains($0.bundleId.lowercased())
            }
            let browserMicInUse = audioProcs.contains { p in
                guard let b = p.bundleId else { return false }
                return p.isRunningInput
                    && Self.matchesTriggerBundle(b, matchers: browserMatchers)
            }
            if !browserApps.isEmpty,
               browserMicInUse || stateMachine.stage != .idle {
                browserTabPids = tabs.pidsWithMeetingTab(browsers: browserApps)
            }
        }
        let primaryAudio = primaryNativeAudio || !browserTabPids.isEmpty
        let meetingWindow: MeetingWindowMatch =
            (stateMachine.stage == .idle && !primaryAudio)
            ? .unavailable(reason: "not queried (idle, no primary signal)")
            : Self.resolveMeetingWindow(ax: ax, apps: nativeApps)
        // Camera gating covers native trigger apps and any browser that is
        // in a meeting tab (camera stays a tie-breaker either way).
        let cameraEligiblePids = nativeApps.map(\.pid) + browserTabPids
        let cameraPids: [pid_t] = (camera.anyCameraRunning() && !cameraEligiblePids.isEmpty)
            ? cameraEligiblePids.sorted() : []
        let now = clock.now
        let inQuiescence: Bool = {
            guard let t = lastDeviceSwapAt else { return false }
            return (now - t) < Self.deviceSwapQuiescenceSeconds
        }()
        return Self.buildEvidence(
            audio: audioProcs,
            now: now,
            matchers: triggerBundleMatchers,
            browserMatchers: browserMatchers,
            browserTabPids: browserTabPids,
            defaultDeviceId: device.currentDeviceId(),
            meetingWindow: meetingWindow,
            cameraPids: cameraPids,
            deviceSwapWithinLast3s: inQuiescence
        )
    }

    /// Walk each trigger-app main PID and return the first matched meeting
    /// window (heuristics are selected per app by bundle id — Teams and Zoom
    /// have different title shapes). `.unavailable` propagates only when
    /// **every** queried PID was unavailable; if even one PID was
    /// successfully introspected and just did not match, that's
    /// `.notMatched`, not unavailable. (A transient launching or quitting
    /// instance must not poison a clean read.)
    // Internal (not private) for the selftest.
    static func resolveMeetingWindow(ax: MeetingWindowProvider,
                                     apps: [RunningAppInfo]) -> MeetingWindowMatch {
        if apps.isEmpty {
            return ax.permissionGranted ? .notMatched
                : .unavailable(reason: "Accessibility permission not granted")
        }
        var sawIntrospectable = false
        var lastUnavailableReason: String?
        for app in apps {
            switch ax.hasMeetingWindow(mainAppPid: app.pid, bundleId: app.bundleId) {
            case .matched(let r, let v):
                return .matched(reason: r, heuristicsVersion: v)
            case .notMatched:
                sawIntrospectable = true
            case .unavailable(let r):
                lastUnavailableReason = r
            }
        }
        if sawIntrospectable { return .notMatched }
        return .unavailable(reason: lastUnavailableReason ?? "no introspectable trigger app")
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

    /// Trailing debounce for provider change notifications. The first
    /// notification of a burst schedules one `evaluate()`
    /// `changeDebounceSeconds` (~300 ms) out; every further notification
    /// inside that window is absorbed into the pending evaluation. The window
    /// deliberately does **not** reset on later notifications, so a continuous
    /// stream of changes can never starve evaluation — worst-case added
    /// latency is a flat 300 ms, far inside the state machine's 3 s confirm
    /// window. The 5 s backstop timer and `start()`'s initial pass call
    /// `evaluate()` directly and are unaffected. Caller must be on `queue`.
    private func scheduleEvaluate() {
        if evaluatePending { return }
        evaluatePending = true
        queue.asyncAfter(deadline: .now() + Self.changeDebounceSeconds) { [weak self] in
            guard let self else { return }
            self.evaluatePending = false
            guard self.running else { return }
            self.evaluate()
        }
    }

    private func evaluate() {
        // Caller is always on `queue` (listener callbacks marshal here and
        // coalesce through `scheduleEvaluate()`, the backstop timer fires on
        // this queue, start()/stop() dispatch here).
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
    static func matchesTriggerBundle(_ bundleId: String, matchers: [String]) -> Bool {
        let b = bundleId.lowercased()
        return matchers.contains(where: { b == $0 || b.hasPrefix($0 + ".") })
    }

    static func buildEvidence(audio: [AudioProcessInfo],
                              now: VirtualTime,
                              matchers: [String],
                              browserMatchers: [String] = [],
                              browserTabPids: [pid_t] = [],
                              defaultDeviceId: AudioDeviceID?,
                              meetingWindow: MeetingWindowMatch,
                              cameraPids: [pid_t],
                              deviceSwapWithinLast3s: Bool) -> CallEvidence {
        let triggerProcs = audio.filter { p in
            guard let b = p.bundleId?.lowercased() else { return false }
            if matchesTriggerBundle(b, matchers: matchers) { return true }
            // A browser process only counts while its app currently shows a
            // Teams meeting tab — plain web-mic use never qualifies.
            return matchesTriggerBundle(b, matchers: browserMatchers)
                && browserTabPids.contains(p.pid)
        }
        let inputPids = triggerProcs.filter(\.isRunningInput).map(\.pid)
        let outputPids = triggerProcs.filter(\.isRunningOutput).map(\.pid)
        let allTriggerPids = Array(Set(triggerProcs.map(\.pid))).sorted()
        return CallEvidence(
            timestamp: now,
            triggerMainPids: allTriggerPids,
            triggerInputPids: inputPids.sorted(),
            triggerOutputPids: outputPids.sorted(),
            triggerCameraPids: cameraPids.sorted(),
            meetingWindow: meetingWindow,
            defaultInputDeviceId: defaultDeviceId,
            deviceSwapWithinLast3s: deviceSwapWithinLast3s
        )
    }
}
