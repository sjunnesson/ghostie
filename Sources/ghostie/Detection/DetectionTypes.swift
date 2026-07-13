import Foundation
import CoreAudio

/// Owned by the caller; releases the listener on dealloc. Concrete providers
/// pass a closure that deregisters their listener(s); the state machine just
/// holds the token alive for as long as the subscription should live.
final class DetectionToken {
    private let cancel: () -> Void
    private var cancelled = false

    init(_ cancel: @escaping () -> Void) { self.cancel = cancel }

    func invalidate() {
        if cancelled { return }
        cancelled = true
        cancel()
    }

    deinit { invalidate() }
}

/// A running macOS application observed via NSWorkspace. Helpers are filtered
/// out at the provider boundary (we never AX-query a helper), so this type
/// only ever describes a main app.
struct RunningAppInfo: Equatable {
    let pid: pid_t
    let bundleId: String
}

/// CoreAudio per-process I/O attribution.
struct AudioProcessInfo: Equatable {
    let pid: pid_t
    let bundleId: String?
    let isRunningInput: Bool
    let isRunningOutput: Bool
}

/// AX meeting-window probe outcome. `.unavailable` is permission denied or
/// the app cannot be introspected; logged distinctly from `.notMatched`.
enum MeetingWindowMatch: Equatable {
    case matched(reason: String, heuristicsVersion: Int)
    case notMatched
    case unavailable(reason: String)

    var isMatched: Bool {
        if case .matched = self { return true }
        return false
    }
}

/// Snapshot of every signal the state machine needs to decide a transition.
/// Built by `DetectionCoordinator` from the providers, fed to
/// `CallStateMachine.evaluate(evidence:)`.
struct CallEvidence: Equatable {
    let timestamp: VirtualTime
    let triggerMainPids: [pid_t]
    let triggerInputPids: [pid_t]
    let triggerOutputPids: [pid_t]
    let triggerCameraPids: [pid_t]
    let meetingWindow: MeetingWindowMatch
    let defaultInputDeviceId: AudioDeviceID?
    let deviceSwapWithinLast3s: Bool

    /// Primary signal: any Teams PID currently doing input I/O.
    var primarySignal: Bool { !triggerInputPids.isEmpty }

    /// Independent corroborators. The state machine requires the primary
    /// signal plus at least one of these to promote to `confirmed`.
    ///
    /// Camera is intentionally a **tie-breaker**, not a stand-alone signal:
    /// CoreMediaIO does not expose per-PID camera attribution publicly, so
    /// `triggerCameraPids` is approximated as "any camera in use AND Teams main
    /// app present". Treating that as a stand-alone corroborator opens a
    /// false-confirm path where Teams briefly holds the mic (a settings
    /// "test your mic" panel, a notification chime) while Zoom holds the
    /// camera. Camera only counts when something stronger already does.
    var corroborators: Set<String> {
        var s: Set<String> = []
        if !triggerOutputPids.isEmpty { s.insert("output") }
        if meetingWindow.isMatched { s.insert("ax") }
        if !triggerCameraPids.isEmpty && !s.isEmpty { s.insert("camera") }
        return s
    }

    var confirmable: Bool { primarySignal && !corroborators.isEmpty }

    /// One-line summary used in transition logs and the `diagnose-detect` CLI.
    var summary: String {
        let inp = triggerInputPids.map(String.init).joined(separator: ",")
        let out = triggerOutputPids.map(String.init).joined(separator: ",")
        let cam = triggerCameraPids.map(String.init).joined(separator: ",")
        let ax: String = {
            switch meetingWindow {
            case .matched(let r, let v): return "ax(matched v\(v):\(r))"
            case .notMatched:            return "ax(no)"
            case .unavailable(let r):    return "ax(unavailable:\(r))"
            }
        }()
        let dev = defaultInputDeviceId.map { "\($0)" } ?? "nil"
        let swap = deviceSwapWithinLast3s ? " swap<3s" : ""
        return "input=[\(inp)] output=[\(out)] camera=[\(cam)] \(ax) device=\(dev)\(swap)"
    }
}
