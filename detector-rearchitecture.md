# Re-architecting Teams call detection

## Context

Ghostie detects Teams calls in `Sources/ghostie/CallDetector.swift` by AND-ing
two weak signals: the default input device is "running somewhere", and any app
whose bundle ID starts with `com.microsoft.teams` is running. Both poll at 2 Hz.
Teams sits in the menu bar all day for most users, so the AND collapses to "mic
is active". The consequences:

- **False positives**: Zoom, Slack huddles, Loom, Voice Memos, Siri while Teams
  is open.
- **False negatives**: Teams on a non-default input, listener-only meetings,
  hardware mute switches.
- **State-splitting bugs**: device hot-swap, Teams crash and relaunch.

Config defaults live in `Config.swift` lines 18 to 38. The detector callbacks
are wired in `Engine.swift` around lines 50 and 74; `minCallSeconds` is enforced
post-hoc at line 145.

## Goal

Replace the current detector with one that commits to a call only when there is
direct evidence Teams owns the active microphone I/O, that survives device
swaps, Teams crashes, and mute toggles without false starts or stops, and that
is fully unit-testable. Optimize for stability and correctness. Complexity is
acceptable. The new path is the path. No feature flag, no A/B scaffolding, old
code deleted (not commented out).

## Design principles

1. **Per-process audio attribution is the primary signal.** The current
   detector's core mistake is using a device-scoped property
   (`kAudioDevicePropertyDeviceIsRunningSomewhere`) where a process-scoped one
   (`kAudioProcessPropertyIsRunningInput`) is available. Switching to PID
   attribution filtered by Teams bundle IDs eliminates Zoom, Slack, Loom, Voice
   Memos, and Siri without requiring any second signal at all.

2. **No single corroborator is a veto.** A meeting confirmed only when AX
   agrees makes Microsoft a single point of failure for Ghostie. Teams ships UI
   changes regularly and Accessibility permission is the scariest TCC prompt on
   the system. Instead: input I/O attributed to Teams is the *primary* signal;
   confirmation requires *at least one* corroborator from a bag of independent
   signals (Teams-PID output I/O, Teams-PID camera, AX meeting window). Each
   corroborator is optional; the absence of all of them keeps the call in
   `candidate` rather than promoting it.

3. **One grace timer, not three.** The original spec proposed `confirmSeconds`,
   `endGraceSeconds`, and `triggerLostGraceSeconds` as three timer paths with
   subtle interactions and at least one specified bug (a Teams crash destroys
   both signals simultaneously, so the FSM races to `idle` on the short timer
   before the crash-recovery window can fire). One unified grace window covers
   mute, device disconnect, brief network blip, and process death. The log
   line names the cause; the code path is the same.

4. **Tentative recording in memory before commit.** From first evidence to
   confirmation, audio is held in a bounded PCM byte ring. On rejection the
   buffer is zeroed; on promotion the ring is flushed to disk and streaming
   writes begin. This is an engineering improvement (faster discard, no FS
   churn, no leak on crash). It is not a privacy fix and will not be sold as
   one in the README.

5. **Push, do not poll.** CoreAudio, CoreMediaIO, and AX property listeners
   replace polling. A 5 s liveness backstop runs only to catch missed callbacks.

6. **Everything testable.** All CoreAudio, CoreMediaIO, AX, and Workspace
   state access goes through protocols. The state machine is exercised by a
   virtual clock and scripted fakes. Tests live inside `ghostie selftest`
   (CLAUDE.md forbids introducing an XCTest target).

7. **Listener leaks are bugs.** Every listener registered, including per-PID
   AX observers, is deregistered on `stop()`, on observed PID death, on AX
   permission revocation, and on dealloc. A debug-only listener registry
   asserts zero remaining observers at end of test.

8. **One serial dispatch queue owns all detector state.** Listener callbacks
   marshal onto it. Nothing reads or writes detector state from any other queue.

## Architecture

### Providers

All under `Sources/ghostie/Detection/`. Each is a protocol with a concrete
implementation and a fake for tests.

```swift
struct RunningAppInfo {
    let pid: pid_t
    let bundleId: String
    let isHelper: Bool
    let mainAppPid: pid_t   // resolves helpers back to the parent app
}

struct AudioProcessInfo {
    let pid: pid_t
    let bundleId: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

final class DetectionToken {
    private let cancel: () -> Void
    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }
    deinit { cancel() }
}

protocol AudioActivityProvider {
    func snapshot() -> [AudioProcessInfo]
    func observe(_ handler: @escaping () -> Void) -> DetectionToken
}

protocol CameraActivityProvider {
    func processesUsingCamera() -> [pid_t]
    func observe(_ handler: @escaping () -> Void) -> DetectionToken
}

protocol DefaultInputDeviceProvider {
    func currentDeviceId() -> AudioDeviceID?
    func observe(_ handler: @escaping () -> Void) -> DetectionToken
}

protocol AppPresenceProvider {
    func teamsApps() -> [RunningAppInfo]  // empty if no Teams running
    func observe(_ handler: @escaping ([RunningAppInfo]) -> Void) -> DetectionToken
}

protocol MeetingWindowProvider {
    func teamsHasMeetingWindow(mainAppPid: pid_t) -> MeetingWindowMatch
    func observe(mainAppPid: pid_t,
                 _ handler: @escaping (MeetingWindowMatch) -> Void) -> DetectionToken
    var permissionGranted: Bool { get }
    func observePermission(_ handler: @escaping (Bool) -> Void) -> DetectionToken
}

enum MeetingWindowMatch {
    case matched(reason: String, heuristicsVersion: Int)
    case notMatched
    case unavailable(reason: String)  // permission denied, app not AX-introspectable
}
```

Concrete implementations:
- `CoreAudioActivityProvider.swift` (input + output attribution per PID)
- `CoreMediaIOCameraActivityProvider.swift` (camera attribution per PID)
- `CoreAudioDefaultDeviceProvider.swift`
- `WorkspaceAppPresenceProvider.swift`
- `AXMeetingWindowProvider.swift`

### Evidence and the state machine

```swift
struct CallEvidence {
    let timestamp: Date
    let teamsMainPids: [pid_t]
    let teamsInputPids: [pid_t]     // Teams PIDs doing input I/O
    let teamsOutputPids: [pid_t]    // Teams PIDs doing output I/O
    let teamsCameraPids: [pid_t]    // Teams PIDs holding camera
    let meetingWindow: MeetingWindowMatch
    let defaultInputDeviceId: AudioDeviceID?
    let deviceSwapWithinLast3s: Bool
}

extension CallEvidence {
    var primarySignal: Bool { !teamsInputPids.isEmpty }
    var corroborators: Set<String> {
        var s: Set<String> = []
        if !teamsOutputPids.isEmpty { s.insert("output") }
        if !teamsCameraPids.isEmpty { s.insert("camera") }
        if case .matched = meetingWindow { s.insert("ax") }
        return s
    }
    var confirmable: Bool { primarySignal && !corroborators.isEmpty }
}
```

States and transitions:

```
idle -> candidate    : primarySignal becomes true
candidate -> confirmed
                     : confirmable continuously for confirmSeconds (default 3)
candidate -> idle    : primarySignal false continuously for 8 s,
                       OR 30 s elapsed without confirmation
confirmed -> ending  : primarySignal false continuously
                       (corroborators allowed to drop too)
ending -> confirmed  : primarySignal returns (any Teams PID, same or new)
                       within endGraceSeconds (default 30)
ending -> idle       : grace elapses; emit onCallStop
```

A single device-swap quiescence pulse (3 s) is layered on top: when the default
input device changes, the state machine ignores `primarySignal=false` for 3 s.
After 3 s, normal evaluation resumes against the new device.

The `endGraceSeconds=30` window covers all "primary signal briefly false"
causes uniformly:
- User mutes via AudioUnit close
- AirPods reconnect
- Teams crashes and relaunches (new PID picks up input I/O)
- Network blip
- Brief device disconnect

The cause is logged; the code path is the same.

## Tasks, in execution order

Each task is its own commit. `ghostie selftest` is green at every step.

### Task 1. Test foundation and state machine

- Define the protocols, `DetectionToken`, `RunningAppInfo`, `AudioProcessInfo`,
  `CallEvidence`, `MeetingWindowMatch`.
- Implement `VirtualClock` and `FakeDetectionWorld` that drive scripted event
  sequences through `CallStateMachine`.
- Implement `CallStateMachine` against the protocols only (no concrete
  providers yet).
- Wire state-machine tests into `runDetectorStateMachineSelfTest()` invoked
  from `ghostie selftest`. Cases:
  - cold start with primary + one corroborator
  - cold start with primary only (must not promote, must time out)
  - mute close mid-call (must not stop)
  - device hot-swap during candidate
  - device hot-swap during confirmed
  - Teams process death with a new Teams PID returning within grace
  - Teams process death with no return (clean end after grace)
  - back-to-back meetings, 6 s gap (collapses) and 35 s gap (splits)
  - AX `unavailable` with output + camera present (still confirmable)
  - all corroborators absent (refuses to promote)
- Old `CallDetector` still drives production. No behavior change.

### Task 2. Per-process audio attribution

- `CoreAudioActivityProvider.swift` using public macOS 14+ APIs:
  - `kAudioHardwarePropertyProcessObjectList`
  - `kAudioProcessPropertyPID`
  - `kAudioProcessPropertyIsRunningInput`
  - `kAudioProcessPropertyIsRunningOutput`
- Resolve PIDs to `RunningAppInfo` via `NSRunningApplication(processIdentifier:)`,
  walking back to the main app for helper PIDs (Teams runs audio off a helper;
  AX must be queried on the main app).
- Register listeners on `kAudioHardwarePropertyProcessObjectList` and on each
  process object's `IsRunningInput` and `IsRunningOutput`. The hardware list
  listener manages add/remove of per-process listeners as processes appear and
  disappear. Deregister all listeners on `stop()` and dealloc.
- Switch production traffic to the new state machine driven by
  `CoreAudioActivityProvider` only, with placeholder no-op providers for AX,
  camera, and default-device. Delete `CallDetector.swift` and its references.
- This commit is the user-visible win. Even with only input + output PID
  attribution, it eliminates the major false positives (Zoom, Slack, Loom,
  Voice Memos, Siri). Output I/O on a Teams PID is enough corroboration for
  almost every real call.

### Task 3. `ghostie diagnose-detect` subcommand

- Live readout for 30 s, refreshing every 500 ms:
  - Current state and time in state
  - `CallEvidence` (every field)
  - List of running input/output processes with PIDs and bundle IDs
  - Default input device id and name
  - Teams meeting window match outcome with `reason` and heuristics version
  - Active grace timer remaining
- Structured JSON mode (`--json`) for parsing in tests.
- Wire into `ghostie selftest` to invoke `diagnose-detect --json --duration 5`
  and assert the output parses.
- Land this third so every subsequent task is verifiable from the CLI without
  re-running real calls.

### Task 4. AX meeting window provider as corroborator

- `AXMeetingWindowProvider.swift` using `AXUIElementCreateApplication(pid)`
  and `AXObserver` on:
  - `kAXWindowCreatedNotification`
  - `kAXUIElementDestroyedNotification`
  - `kAXTitleChangedNotification`
  - `kAXFocusedWindowChangedNotification`
- Per-PID observers tracked in a map keyed by main-app PID. On PID death,
  tear down the observer for that PID. On AX permission revocation, tear
  down all observers and emit `.unavailable` for every PID.
- Heuristics in `MeetingWindowHeuristics.swift`:
  - Title contains "Meeting" or "Call"
  - Title matches `^.* \| Microsoft Teams$` with a meeting indicator
  - Window with role description "Meeting controls" or "Call window"
  - Heuristics version constant starts at 1; bump it when changing
- Unit-test heuristics against captured fixtures inside `selftest`.
- AX permission flow:
  - Prompt on first launch
  - `NSAccessibilityUsageDescription` in `Info.plist`
  - If denied at startup: detector runs without AX corroboration. Still
    detects calls via output/camera. Surfaces a menu bar info item ("AX
    disabled: detection works but won't pick up some listener-only browser
    meetings").
  - If revoked at runtime: provider emits `.unavailable`, state machine
    continues without that corroborator.
- Tests in `selftest`: permission-denied scenario still records when output
  corroborator is present; permission-revoked-mid-call does not stop the
  ongoing recording.

### Task 5. Camera activity provider as corroborator

- `CoreMediaIOCameraActivityProvider.swift` using CoreMediaIO public APIs
  available since Catalina:
  - `kCMIOHardwarePropertyDevices` to enumerate
  - `kCMIODevicePropertyDeviceIsRunningSomewhere` per device
  - Per-process attribution where the device exposes it
- Listener on device list changes; per-device running-state listeners.
- Camera-on-Teams is a near-conclusive corroborator. Trivial once the
  pattern from task 2 exists.
- Test in `selftest`: mic muted from start, video on, output present.
  State machine reaches `confirmed`.

### Task 6. Default-input-device provider and swap quiescence

- `CoreAudioDefaultDeviceProvider.swift` with listener on
  `kAudioHardwarePropertyDefaultInputDevice`.
- On change, the state machine sets `deviceSwapWithinLast3s=true` for 3 s,
  during which `primarySignal=false` does not advance toward `ending`.
- Tests in `selftest`: hot-swap during candidate (does not lose the
  candidate); hot-swap during confirmed (does not start `ending`).

### Task 7. App presence provider, push-based

- `WorkspaceAppPresenceProvider.swift` using
  `NSWorkspace.didLaunchApplicationNotification` and
  `NSWorkspace.didTerminateApplicationNotification`.
- Maintain internal cache keyed by bundle ID. Provide both main-app and
  helper PIDs.
- Replace `triggerBundlePrefixes` with `triggerBundleIds` defaulting to
  the verified set:
  - `com.microsoft.teams` (classic Teams)
  - `com.microsoft.teams2` (new Teams)
  - Plus any helper bundle IDs discovered against a running Teams instance
- Keep `triggerBundlePrefixes` readable for one release with a deprecation
  log line on load.

### Task 8. PCM byte ring buffer in AudioRecorder

- `AudioRecorder` converts ScreenCaptureKit `CMSampleBuffer`s through the
  existing `AudioChunkConverter` to 16 kHz mono PCM first (the pipeline
  already does this on the disk path).
- The PCM bytes feed a bounded ring (cap 30 s, ≈1 MB) until the state
  machine emits `confirmed`. On `confirmed`, the ring flushes to
  `me.wav`/`participants.wav` and streaming writes begin. On `candidate ->
  idle`, the ring is zeroed and `AudioRecorder` shuts down without
  touching disk.
- Move `minCallSeconds` enforcement out of `Engine.swift` line 145. The
  state machine never promotes a sub-`minCallSeconds` candidate; the
  post-hoc disk delete is gone.
- This is framed as an engineering improvement in the PR description. It
  is not framed as a privacy fix.

### Task 9. Browser Teams as opt-in

- `detectBrowserTeams: Bool` in `Config`, default `false`.
- When true, `WorkspaceAppPresenceProvider` also returns browser PIDs:
  - `com.apple.Safari`
  - `com.google.Chrome`
  - `com.microsoft.edgemac`
  - `company.thebrowser.Browser` (Arc)
- Browser confirmation requires:
  - Browser PID doing input I/O, AND
  - An active TLS connection from that PID to `*.teams.microsoft.com`
    or `*.teams.live.com`, observed via `proc_listfds` +
    `proc_pidfdinfo` + a socket peer-address lookup
- The network probe is the stronger signal than AX title matching for
  browser meetings. If `proc_listfds`-based peer-address inspection turns
  out to require entitlements Ghostie does not have, fall back to
  AX-title heuristics on browser windows with a clear docs warning about
  false positives. Decide during implementation, not now.
- Off by default. README documents the increased false-positive risk
  honestly.

### Task 10. Documentation and PR description

- Rewrite `README.md` "How it works" and "Limitations" sections in the
  editorial register Ghostie uses everywhere else. No em-dashes. Name the
  residual risks plainly:
  - AX heuristic fragility (Teams UI can change at any release)
  - Browser-Teams detection is an approximation even with the network probe
  - The detector is Teams-only by design
- New config keys (`triggerBundleIds`, `detectBrowserTeams`, default-tuned
  `endGraceSeconds=30`) documented in the config table.
- PR description includes a before/after table per task, a list of every
  CoreAudio, CoreMediaIO, and AX API touched with the macOS version that
  introduced it, and a candid residual-risks section.

## Constraints

- **macOS 15+** target (matches CLAUDE.md). No back-compat code paths.
- **Public APIs only.** If a private API materially improves stability, it
  comes as a separate PR with written justification. Not in this PR.
- `CallDetector`'s public surface (`start`, `stop`, `onCallStart`,
  `onCallStop`) is preserved so `Engine.swift` is not touched beyond the
  `minCallSeconds` removal in task 8.
- Existing `config.json` keys remain readable. New keys get defaults.
  `Config`'s hand-written `init(from:)` is extended for every new key
  (CLAUDE.md gotcha: synthesized `Decodable` throws on missing keys; new
  keys must use `decodeIfPresent ?? default`).
- Old `CallDetector` and all references deleted, not commented out.
- **Swift 5 language mode stays.** CLAUDE.md is explicit: no `.v6`.
- **No XCTest target.** All tests inside `ghostie selftest`. Add
  `runDetectorStateMachineSelfTest()` and call from `main.swift`.
- Detector class remains `@unchecked Sendable` with manual queue
  synchronization. CLAUDE.md is explicit: no actor isolation.

## Acceptance criteria

- `swift build` passes with zero warnings.
- `./scripts/build-app.sh` produces a working signed app.
- `ghostie selftest` passes, covering at minimum:
  1. Cold start with primary + one corroborator (output)
  2. Cold start with primary only, no corroborators (refuses to promote)
  3. Listener-only meeting (Teams output present, no input from user)
  4. Camera-only corroboration (mic muted from start, video on)
  5. Device hot-swap during candidate
  6. Device hot-swap during confirmed
  7. Teams crash with another Teams PID resuming input within grace
  8. Teams crash with no resumption (clean end after grace)
  9. Mute via AudioUnit close mid-call (does not split)
  10. Back-to-back meetings, 6 s gap (collapses) and 35 s gap (splits)
  11. AX permission denied at startup (records via output corroborator)
  12. AX permission revoked mid-call (continues current recording)
- Listener-lifecycle test asserts zero registered observers after `stop()`,
  including per-PID AX observers after simulated PID death.
- `ghostie selftest` invokes `diagnose-detect --json --duration 5` and
  asserts structured output parses.
- Manual validation matrix in the PR description, with results per row:
  - real 1:1 Teams call
  - Teams meeting with 5+ participants
  - Zoom call with Teams open in the background (must NOT trigger)
  - Slack huddle with Teams open (must NOT trigger)
  - Loom recording with Teams open (must NOT trigger)
  - Voice Memos with Teams open (must NOT trigger)
  - Siri invocation with Teams open (must NOT trigger)
  - AirPods auto-handoff at 30 s into a call (does not split)
  - Teams force-quit at 2 min into a call, relaunch within 20 s
  - Teams force-quit with no relaunch (clean end after grace)
  - User-muted segment of 60 s mid-call (does not split)
  - Back-to-back meetings with no gap (collapses to one)
  - AX permission denied (still records via output corroborator)
  - Listener-only meeting (no mic input, output + AX present)
- README "How it works" and "Limitations" sections rewritten to match new
  behavior. No em-dashes anywhere in docs.

## Out of scope

- Per-person diarization
- Anything in the whisper or Claude Code summarization stages
- Windows or Linux
- Detection of meetings outside Teams (Zoom, Meet). The provider
  architecture makes these straightforward to add later; do not implement
  them now.

## Working order summary

1. State machine + tests (no behavior change)
2. Per-process audio attribution, ship to production, delete old detector
3. `ghostie diagnose-detect` CLI tool
4. AX corroborator with permission lifecycle
5. Camera corroborator
6. Device-swap quiescence
7. App presence push-based
8. PCM ring buffer in AudioRecorder; remove post-hoc `minCallSeconds`
9. Browser Teams opt-in
10. Docs and PR description

Each task is its own commit with green `swift build` and green
`ghostie selftest`.

## Residual risks

- **AX heuristics drift.** Microsoft changes the Teams UI on its own
  cadence. The versioned `MeetingWindowHeuristics` constant gives us
  something to bump when it happens, but we will not always detect the
  change before users do. The decision to make AX a corroborator rather
  than a veto (design principle 2) is what stops a Teams UI change from
  breaking detection wholesale. Output + camera will keep working.
- **Browser-Teams approximation.** Even with the network probe, browser
  meetings are inferred, not observed. The default-off posture is the
  right one; the docs name the limitation plainly.
- **CoreAudio process attribution depends on Teams routing audio through
  HAL.** If Teams moves to a private I/O path, `IsRunningInput` may not
  fire. Mitigation: the default-input-device-running fallback stays
  available as a degraded signal, off by default, surfaced via
  `diagnose-detect`.
- **AX permission denial blocks one of three corroborators.** A user who
  denies AX still gets correct detection via output and camera in
  practice. A user who denies AX *and* never uses output (impossible: a
  meeting plays back other participants) is the only path to silent
  failure, and that path does not exist outside test fixtures.
