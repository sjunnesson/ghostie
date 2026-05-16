import Foundation
import CoreAudio
import AppKit

/// Detects Teams calls with no bot and no Graph API:
///   1. The default input device is "running somewhere" (some app is actively
///      using the microphone) — public CoreAudio property.
///   2. Microsoft Teams is running (so we attribute the mic session to a call).
///
/// A short debounce avoids false starts; a configurable grace period rides over
/// mute toggles and brief silences so a call isn't split into pieces.
final class CallDetector {
    private let config: Config
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "ghostie.detector")

    private var inCall = false
    private var startConfirms = 0
    private var lastMicActive = Date.distantPast

    var onCallStart: (() -> Void)?
    var onCallStop: (() -> Void)?

    init(config: Config) {
        self.config = config
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: config.pollIntervalSeconds)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
        Log.info("Call detector started (polling every \(config.pollIntervalSeconds)s).")
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let micActive = Self.isDefaultInputRunningSomewhere()
        let triggerRunning = !config.requireTriggerApp || isTriggerAppRunning()
        let qualifies = micActive && triggerRunning

        if qualifies { lastMicActive = Date() }

        if !inCall {
            if qualifies {
                startConfirms += 1
                // Two consecutive positive polls before we commit.
                if startConfirms >= 2 {
                    inCall = true
                    startConfirms = 0
                    Log.ok("Teams call detected — starting capture.")
                    onCallStart?()
                }
            } else {
                startConfirms = 0
            }
        } else {
            // In a call: end only after sustained microphone inactivity.
            let idle = Date().timeIntervalSince(lastMicActive)
            if idle >= config.endGraceSeconds {
                inCall = false
                Log.ok("Teams call ended (mic idle \(Int(idle))s) — finalizing.")
                onCallStop?()
            }
        }
    }

    private func isTriggerAppRunning() -> Bool {
        for app in NSWorkspace.shared.runningApplications {
            guard let bid = app.bundleIdentifier?.lowercased() else { continue }
            for prefix in config.triggerBundlePrefixes where bid.hasPrefix(prefix.lowercased()) {
                return true
            }
        }
        return false
    }

    // MARK: CoreAudio

    /// True if the system default input device currently has active I/O in any
    /// process (kAudioDevicePropertyDeviceIsRunningSomewhere).
    static func isDefaultInputRunningSomewhere() -> Bool {
        guard let device = defaultInputDevice() else { return false }
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let err = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running)
        return err == noErr && running != 0
    }

    static func defaultInputDevice() -> AudioDeviceID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard err == noErr, device != 0 else { return nil }
        return device
    }
}
