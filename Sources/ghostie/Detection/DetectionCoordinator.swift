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
    /// Lowercased browser bundle IDs eligible for the meeting-tab probe.
    /// Empty when `detectBrowserMeetings` is off — every browser branch in
    /// `buildEvidenceLocked` then short-circuits.
    private let browserMatchers: [String]
    private let tabs: BrowserTabProvider
    /// Source derived from the most recent evidence build (queue-only), and
    /// its value frozen at the moment the state machine last confirmed a
    /// call. `currentCallSource()` serves the frozen one so Engine can label
    /// the recording even if evidence shifts mid-call. The frozen copy is
    /// guarded by `sourceLock`, NOT the queue: Engine reads it synchronously
    /// from inside the onCallStart callback, which itself runs on `queue` —
    /// a `queue.sync` accessor would deadlock there.
    private var lastSource: CallSource?
    private let sourceLock = NSLock()
    private var sourceAtCallStart: CallSource?   // sourceLock-guarded

    /// Who the meeting window says is in the call, unioned over the whole
    /// session. Unlike `CallSource` this is NOT frozen at confirm: people join
    /// late, and the roster is only readable while whichever UI carries it
    /// (the People panel, the tiles) happens to be on screen — so it is
    /// sampled repeatedly and only ever grows. sourceLock-guarded, for the
    /// same reason the frozen source is: Engine reads it from inside a
    /// coordinator callback running on `queue`.
    private let participants: ParticipantRosterProvider
    private var rosterSoFar = MeetingRoster()    // sourceLock-guarded
    private var lastRosterSampleAt: TimeInterval = -.greatestFiniteMagnitude
    /// The roster changes on the timescale of people joining, not of audio
    /// evidence, and the AX walk is by far the most expensive probe here.
    private static let rosterSampleIntervalSeconds: TimeInterval = 20

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
         participants: ParticipantRosterProvider = AXParticipantRosterProvider(),
         clock: Clock = SystemClock()) {
        let mainIds = config.triggerBundleIds.map { $0.lowercased() }
        // Browser meetings (Teams / Google Meet tabs) are opt-in: with the
        // flag off the browser matcher list is empty and browsers never get
        // CoreAudio listeners, presence tracking, or AX tab probes.
        let browserIds = config.detectBrowserMeetings
            ? config.browserBundleIds.map { $0.lowercased() } : []
        self.config = config
        self.audio = audio ?? CoreAudioActivityProvider(matchers: mainIds + browserIds)
        self.ax = ax
        self.camera = camera
        self.device = device
        self.tabs = tabs
        self.participants = participants
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
            // Fires on `queue` from inside evaluate(), so `lastSource` is
            // the source of the exact evidence that promoted this call.
            self.sourceLock.withLock {
                self.sourceAtCallStart = self.lastSource
                // Keep whatever this call has already contributed: the tab
                // probe (and therefore the roster) runs from `candidate`
                // onward, so the pre-confirm samples belong to this call.
            }
            let app = self.lastSource?.rawValue ?? "meeting app"
            Log.ok("Call detected (\(app), session \(sid.uuidString.prefix(8))) — starting capture.")
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
        // Browser meetings (opt-in): the tab probe runs under the same cost
        // gate as the meeting-window walk — only when a browser is actually
        // using the mic (or a session is already past idle) do we pay the
        // AX title read. A browser PID is then eligible as primary only
        // while one of its windows shows a Teams or Google Meet meeting tab.
        var browserTabHits: [pid_t: CallSource] = [:]
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
                browserTabHits = tabs.meetingTabs(browsers: browserApps)
            }
        }
        let browserTabPids: [pid_t] = browserTabHits.keys.sorted()
        sampleRosterIfDue(browserTabHits: browserTabHits, apps: allApps)
        let primaryAudio = primaryNativeAudio || !browserTabPids.isEmpty
        lastSource = Self.deriveSource(audio: audioProcs,
                                       matchers: triggerBundleMatchers,
                                       tabHits: browserTabHits)
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

    /// Which app the current (or most recent) call belongs to, frozen at the
    /// moment the state machine confirmed it. Engine reads this from its
    /// onCallStart handler to label the recording; between calls the value is
    /// stale and unread. nil when the trigger was a custom (non-Teams,
    /// non-Zoom) bundle id the user added — callers fall back to a generic
    /// label. Lock-guarded (not queue-hopped) so it is safe to call from
    /// inside the coordinator's own callbacks, which run on `queue`.
    func currentCallSource() -> CallSource? {
        sourceLock.withLock { sourceAtCallStart }
    }

    /// Everyone the meeting window has named during this call. Empty is the
    /// normal answer for a desktop Teams/Zoom call, for a browser call whose
    /// roster UI was never on screen, and whenever AX is not granted.
    func currentRoster() -> MeetingRoster {
        sourceLock.withLock { rosterSoFar }
    }

    /// Clears the accumulated roster so the next call starts from nothing.
    /// Called when a session ends rather than when one begins, so the value
    /// is still readable from Engine's stop handler.
    func clearRoster() {
        sourceLock.withLock { rosterSoFar = MeetingRoster() }
    }

    /// Walk the meeting browser's AX tree for participant names, at most
    /// every `rosterSampleIntervalSeconds`. Only browsers the tab probe just
    /// flagged are walked, so this never touches an ordinary browser window.
    private func sampleRosterIfDue(browserTabHits: [pid_t: CallSource],
                                   apps: [RunningAppInfo]) {
        guard !browserTabHits.isEmpty else { return }
        let now = clock.now
        guard now - lastRosterSampleAt >= Self.rosterSampleIntervalSeconds else { return }
        lastRosterSampleAt = now
        let meetingBrowsers = apps.filter { browserTabHits[$0.pid] != nil }
        guard !meetingBrowsers.isEmpty else { return }
        let found = participants.roster(browsers: meetingBrowsers)
        guard !found.isEmpty else { return }
        sourceLock.withLock {
            let before = rosterSoFar
            rosterSoFar = before.merged(with: found)
            if rosterSoFar != before {
                Log.info("Meeting roster: "
                    + (rosterSoFar.others.isEmpty ? "(no other participants named)"
                       : rosterSoFar.others.joined(separator: ", "))
                    + (rosterSoFar.selfName.map { " (you: \($0))" } ?? ""))
            }
        }
    }

    /// Which app the evidence points at: the trigger app actually holding the
    /// mic wins (input outranks output-only, then lowest PID for
    /// determinism), else the lowest-PID browser meeting tab's site. Static +
    /// pure for the selftest.
    static func deriveSource(audio: [AudioProcessInfo],
                             matchers: [String],
                             tabHits: [pid_t: CallSource]) -> CallSource? {
        let native = audio
            .filter { p in
                guard let b = p.bundleId else { return false }
                return matchesTriggerBundle(b, matchers: matchers)
            }
            .sorted { a, b in
                if a.isRunningInput != b.isRunningInput { return a.isRunningInput }
                return a.pid < b.pid
            }
        for p in native {
            if let b = p.bundleId, let s = CallSource(bundleId: b) { return s }
        }
        return tabHits.min { $0.key < $1.key }?.value
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
            // meeting tab — plain web-mic use never qualifies.
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
