import Foundation
import CoreAudio

/// Public-surface shim that `Engine` already wires to. The actual detection
/// logic lives in `Detection/DetectionCoordinator` + `CallStateMachine` +
/// concrete providers (`CoreAudioActivityProvider`, AX/camera/device coming in
/// later tasks). See `detector-rearchitecture.md`.
///
/// Why a shim and not a deletion: `Engine.swift` reads `onCallStart` /
/// `onCallStop`, calls `start()` / `stop()`, and `cmdDoctor` calls
/// `defaultInputDevice()`. Preserving the surface keeps task 2 a pure
/// detector replacement; the engine doesn't change until task 8 (PCM ring
/// buffer in `AudioRecorder`).
final class CallDetector {
    private let coordinator: DetectionCoordinator

    var onCallStart: (() -> Void)? {
        didSet {
            coordinator.onCallStart = { [weak self] _ in self?.onCallStart?() }
        }
    }
    var onCallStop: (() -> Void)? {
        didSet {
            coordinator.onCallStop = { [weak self] _ in self?.onCallStop?() }
        }
    }

    init(config: Config) {
        self.coordinator = DetectionCoordinator(config: config)
    }

    func start() { coordinator.start() }
    func stop()  { coordinator.stop() }

    /// System default input device id (used by `cmdDoctor`).
    static func defaultInputDevice() -> AudioDeviceID? {
        CoreAudioActivityProvider.defaultInputDevice()
    }
}
