import Foundation
import CoreAudio

/// Public-surface shim that `Engine` already wires to. The actual detection
/// logic lives in `Detection/DetectionCoordinator` + `CallStateMachine` +
/// the concrete providers (audio activity, AX meeting window, camera,
/// default-device swap, app presence). See `detector-rearchitecture.md`.
///
/// Why a shim and not a deletion: `Engine.swift` reads `onCallStart` /
/// `onCallStop`, calls `start()` / `stop()`, and `cmdDoctor` calls
/// `defaultInputDevice()`. Preserving the surface keeps the engine decoupled
/// from the detection internals.
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
    /// First primary evidence (idle → candidate): begin a tentative capture
    /// so the confirm window's audio is kept if the call confirms.
    var onTentativeStart: (() -> Void)? {
        didSet {
            coordinator.onTentativeStart = { [weak self] _ in self?.onTentativeStart?() }
        }
    }
    /// Candidate demoted without confirming: throw the tentative capture away.
    var onTentativeDiscard: (() -> Void)? {
        didSet {
            coordinator.onTentativeDiscard = { [weak self] _ in self?.onTentativeDiscard?() }
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
