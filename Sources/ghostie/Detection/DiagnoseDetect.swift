import Foundation

/// Live readout of detector state, refreshing at ~2 Hz. Operator's first stop
/// for false-positive / false-negative investigation in the field.
///
/// Two modes:
///   - Plain (default): one human-readable line per tick.
///   - `--json`: one line-delimited JSON object per tick, suitable for
///     piping through `jq` or asserting in tests.
enum DiagnoseDetect {

    /// Run for `duration` seconds against a real `DetectionCoordinator`,
    /// emitting one line per tick to `sink`. The sink decouples printing
    /// from the loop so `ghostie selftest` can capture lines in-memory and
    /// assert each one parses.
    static func run(config: Config,
                    duration: TimeInterval,
                    jsonMode: Bool,
                    refreshSeconds: TimeInterval = 0.5,
                    sink: (String) -> Void) {
        let coordinator = DetectionCoordinator(config: config)
        coordinator.start()
        // Give listeners a beat to settle before the first read.
        Thread.sleep(forTimeInterval: 0.1)

        if !jsonMode {
            sink("ghostie diagnose-detect — \(format(duration))s readout, refresh \(format(refreshSeconds))s")
            sink(String(repeating: "=", count: 72))
        }

        let endAt = Date().addingTimeInterval(duration)
        while Date() < endAt {
            let line = jsonMode
                ? jsonLine(coordinator: coordinator)
                : prettyLine(coordinator: coordinator)
            sink(line)
            Thread.sleep(forTimeInterval: refreshSeconds)
        }
        coordinator.stop()
    }

    // MARK: - Renderers

    private static func prettyLine(coordinator: DetectionCoordinator) -> String {
        let s = coordinator.snapshot()
        let sid = s.sessionId?.uuidString.prefix(8).description ?? "-"
        let ts = ISO8601DateFormatter().string(from: Date())
        return "[\(ts)] stage=\(s.stage.rawValue) sid=\(sid) \(s.evidence.summary)"
    }

    private static func jsonLine(coordinator: DetectionCoordinator) -> String {
        let s = coordinator.snapshot()
        var dict: [String: Any] = [
            "ts": Date().timeIntervalSince1970,
            "stage": s.stage.rawValue,
            "session_id": s.sessionId?.uuidString ?? NSNull(),
            "transitions_count": s.transitionsCount,
            "evidence": evidenceDict(s.evidence)
        ]
        // Surface the most recent transition reason so streamed JSON is
        // self-explanatory without context.
        if let last = s.lastTransition {
            dict["last_transition"] = [
                "from": last.from.rawValue,
                "to": last.to.rawValue,
                "reason": last.reason
            ]
        }
        guard let data = try? JSONSerialization.data(
                withJSONObject: dict,
                options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"json encode failed\"}"
        }
        return s
    }

    private static func evidenceDict(_ ev: CallEvidence) -> [String: Any] {
        var meeting: [String: Any]
        switch ev.meetingWindow {
        case .matched(let reason, let v):
            meeting = ["status": "matched", "reason": reason, "heuristics_version": v]
        case .notMatched:
            meeting = ["status": "not_matched"]
        case .unavailable(let reason):
            meeting = ["status": "unavailable", "reason": reason]
        }
        return [
            "teams_main_pids": ev.teamsMainPids,
            "teams_input_pids": ev.teamsInputPids,
            "teams_output_pids": ev.teamsOutputPids,
            "teams_camera_pids": ev.teamsCameraPids,
            "meeting_window": meeting,
            "default_input_device_id": (ev.defaultInputDeviceId.map { Int($0) as Any }) ?? NSNull(),
            "device_swap_within_last_3s": ev.deviceSwapWithinLast3s,
            "primary_signal": ev.primarySignal,
            "confirmable": ev.confirmable,
            "corroborators": ev.corroborators.sorted()
        ]
    }

    private static func format(_ s: TimeInterval) -> String {
        s == s.rounded() ? "\(Int(s))" : String(format: "%.1f", s)
    }
}
