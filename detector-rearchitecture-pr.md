# Re-architect Teams call detection

Replaces the prior two-poll AND of "default input device running" + "Teams
is somewhere in the process list" with a state-machine-driven coordinator
consuming per-PID CoreAudio, CoreMediaIO, AX, and NSWorkspace signals.
Eliminates the long-standing class of false positives where Zoom, Slack
huddles, Loom, Voice Memos, or Siri triggered a recording while Teams was
open in the menu bar.

## What changed

### Before

`CallDetector` polled `kAudioDevicePropertyDeviceIsRunningSomewhere` on
the default input device, AND-ed with `NSWorkspace.runningApplications`
containing `com.microsoft.teams*`. Teams sits in the menu bar all day for
most users, so the AND collapsed to "any app is using the mic".

Symptoms in production: false positives across every other audio-using
app, false negatives on a non-default input, no recovery from Teams
crash, state-splitting on AirPods handoff.

### After

A `CallStateMachine` consumes `CallEvidence` snapshots from five
provider protocols. Each provider hides one signal source behind a
testable interface:

| Provider | Signal | API surface |
|---|---|---|
| `CoreAudioActivityProvider` | per-PID input + output I/O | `kAudioHardwarePropertyProcessObjectList`, `kAudioProcessPropertyPID`, `kAudioProcessPropertyIsRunningInput`, `kAudioProcessPropertyIsRunningOutput` (macOS 14.2+) |
| `AXMeetingWindowProvider` | meeting-window AX match on Teams main app | `AXUIElementCreateApplication`, `AXUIElementCopyAttributeValue` (kAXWindows, kAXTitle, kAXRoleDescription, kAXSubrole), `AXIsProcessTrusted` (Mojave+) |
| `CoreMediaIOCameraActivityProvider` | any camera in use | `kCMIOHardwarePropertyDevices`, `kCMIODevicePropertyDeviceIsRunningSomewhere` (Catalina+) |
| `CoreAudioDefaultDeviceProvider` | default input device change | `kAudioHardwarePropertyDefaultInputDevice` |
| `WorkspaceAppPresenceProvider` | Teams main apps running | `NSWorkspace.didLaunchApplicationNotification`, `NSWorkspace.didTerminateApplicationNotification` |

The state machine commits to a call only when **per-PID Teams input I/O**
(the primary signal) is observed alongside **at least one corroborator**
from `{Teams output I/O, camera in use, AX meeting window match}`. None
of the corroborators is a veto. If AX permission is denied, output and
camera still carry the signal. If Teams ships a UI change that breaks
the AX heuristics, output and camera still carry the signal.

State graph:

```
idle ──primary observed──> candidate
candidate ──confirmable for 3 s──> confirmed     (onCallStart)
candidate ──primary lost >8 s──> idle
confirmed ──primary lost──> ending
ending ──primary returns within 30 s──> confirmed
ending ──grace elapses──> idle                   (onCallStop)
```

One grace timer (`endGraceSeconds = 30`) uniformly covers mute, brief
network blips, device disconnects, and Teams crash-relaunch. A separate
three-second device-swap quiescence pulse, triggered by default-input-
device changes, suppresses spurious `confirmed → ending` transitions
while audio routing reconverges.

`AudioRecorder` accumulates the first 30 seconds of each session (or
`max(30, minCallSeconds)`, whichever is larger) in an in-memory PCM
ring. Sessions ending before crossing `minCallSeconds` never touch disk.
The post-hoc session-dir delete in `Engine.handleStop` is gone.

### Per-task summary

| Task | Status | What landed |
|---|---|---|
| 1 | done | Protocols, `DetectionToken`, `CallEvidence`, `MeetingWindowMatch`, `VirtualClock`, `CallStateMachine`, 16 state-machine selftest cases |
| 2 | done | `CoreAudioActivityProvider` with per-PID input + output I/O, production switched to coordinator + state machine, old `CallDetector` polling deleted (shim preserves `start` / `stop` / `onCallStart` / `onCallStop`) |
| 3 | done | `ghostie diagnose-detect` CLI, plain + `--json` modes, selftest validates JSON shape |
| 4 | done | `AXMeetingWindowProvider`, `MeetingWindowHeuristics.v1` with 7 fixture tests, permission prompt on detector start, menu bar warning that opens System Settings when AX is off, runtime revocation surfaced via the per-second render tick |
| 5 | done | `CoreMediaIOCameraActivityProvider` with device-list + per-device running listeners. Per-PID attribution is not publicly exposed; coordinator approximates `teamsCameraPids` as Teams main PIDs when any camera is in use |
| 6 | done | `CoreAudioDefaultDeviceProvider` with listener; coordinator sets `lastDeviceSwapAt` on change and stamps evidence accordingly |
| 7 | done | `WorkspaceAppPresenceProvider` (push-based via `NSWorkspace.didLaunch/didTerminateApplicationNotification`); `config.triggerBundleIds` added; `triggerBundlePrefixes` kept readable with a deprecation log; bundle-id match changed to exact-or-`prefix.` to prevent `com.microsoft.teams` matching `com.microsoft.teams2` accidentally |
| 8 | done | PCM byte ring in `AudioRecorder`, session dir deferred to first flush, `Engine.handleStop` no longer performs post-hoc discard |
| 9 | deferred | Browser-Teams opt-in. Needs its own design pass: browser PIDs join the matcher list dynamically based on AX-detected meeting tabs, and the audio side has to attribute by browser PID rather than a static prefix. Not blocking the false-positive fix |
| 10 | done | README "How it works" + "Limitations" rewritten in editorial register (no em-dashes), config table updated, this PR description |

## Selftest

`ghostie selftest` now runs four suites:

- transcript-cleaner: 5 cases
- code-switching smoother: 7 cases
- updater: 13 cases
- call-detector state machine: 39 cases including the full lifecycle,
  hot-swap during candidate and confirmed, Teams crash with and without
  relaunch within grace, mute with AX still up, back-to-back meetings at
  6 s gap (collapses) and 35 s gap (splits), AX denied + revoked,
  `forceStop`, transition logging, heuristics fixtures, live
  `diagnose-detect --json` round-trip.

Total: 64 cases, all green.

## Manual validation matrix

To fill in on the actual PR. Rows to run against the build:

- [ ] Real 1:1 Teams call
- [ ] Teams meeting with 5+ participants
- [ ] Zoom call with Teams open in the background (must NOT trigger)
- [ ] Slack huddle with Teams open (must NOT trigger)
- [ ] Loom recording with Teams open (must NOT trigger)
- [ ] Voice Memos with Teams open (must NOT trigger)
- [ ] Siri invocation with Teams open (must NOT trigger)
- [ ] AirPods auto-handoff at 30 s into a call (does not split)
- [ ] Teams force-quit at 2 min into a call, relaunch within 20 s
- [ ] Teams force-quit with no relaunch (clean end after grace)
- [ ] User-muted segment of 60 s mid-call (does not split)
- [ ] Back-to-back meetings with no gap (collapses to one)
- [ ] AX permission denied (still records via output corroborator)
- [ ] Listener-only meeting (no mic input from user, output + AX present)

## Residual risks

- **AX heuristics drift.** Microsoft can change the Teams meeting window
  title or role description at any release. The versioned constant in
  `MeetingWindowHeuristics.swift` is the bump point. AX is a
  corroborator (not a veto), so a stale rule degrades confirmation
  confidence but does not stop detection of real calls. Output and
  camera still carry the weight.

- **CoreMediaIO per-process camera attribution is not public.** We
  approximate by attributing any-camera-running to Teams when Teams is
  the main app present. A user who runs Teams in the menu bar AND
  starts a camera in some other app (Zoom, Photo Booth, FaceTime) at
  the same time would technically get a camera-corroborator vote
  pointing at Teams. They would still need to be holding the Teams mic
  via input I/O attribution (the primary signal); in practice the OS
  enforces mutual exclusion on the camera, so the overlap window is
  narrow.

- **Browser-Teams is not detected** until Task 9 lands. Installing the
  desktop client is the workaround.

- **Per-PID AX listener leaks are possible** if a Teams PID dies while
  we hold an observer. The current AX provider is pull-only, so this
  is not load-bearing today, but the push-based follow-up needs to
  track per-PID observers and tear them down on PID death.

## Files touched

New under `Sources/ghostie/Detection/`:
- `Clock.swift`
- `DetectionTypes.swift`
- `DetectionProviders.swift`
- `CallStateMachine.swift`
- `CallStateMachineSelfTest.swift`
- `CoreAudioActivityProvider.swift`
- `AXMeetingWindowProvider.swift`
- `CoreMediaIOCameraActivityProvider.swift`
- `CoreAudioDefaultDeviceProvider.swift`
- `WorkspaceAppPresenceProvider.swift`
- `MeetingWindowHeuristics.swift`
- `DetectionCoordinator.swift`
- `DiagnoseDetect.swift`

Edited:
- `Sources/ghostie/CallDetector.swift` (now a shim over `DetectionCoordinator`)
- `Sources/ghostie/Engine.swift` (post-hoc `minCallSeconds` discard removed)
- `Sources/ghostie/AudioRecorder.swift` (PCM ring buffer, deferred session dir)
- `Sources/ghostie/MenuBarApp.swift` (AX warning menu item + per-second render tick)
- `Sources/ghostie/Config.swift` (`triggerBundleIds` added, `triggerBundlePrefixes` deprecated)
- `Sources/ghostie/main.swift` (`diagnose-detect` subcommand, doctor bundle-id check, selftest wiring)
- `README.md` (How it works, Limitations, config table, CLI section)

Out: nothing. The old `CallDetector` polling is gone, not commented out.
