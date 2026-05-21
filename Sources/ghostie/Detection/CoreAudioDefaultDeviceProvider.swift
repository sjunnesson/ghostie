import Foundation
import CoreAudio

/// Observes the system default input device (`kAudioHardwarePropertyDefaultInputDevice`).
/// The coordinator uses change notifications to trigger a 3 s "quiescence
/// pulse" that prevents a transient primary-signal drop from collapsing a
/// confirmed call when the user, say, unplugs headphones mid-meeting.
final class CoreAudioDefaultDeviceProvider: DefaultInputDeviceProvider {

    private let listenerQueue = DispatchQueue(label: "ghostie.defaultdevice")
    private let fanout = ChangeFanout()
    private var teardown: (() -> Void)?

    init() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notify()
        }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let queue = listenerQueue
        let sys = AudioObjectID(kAudioObjectSystemObject)
        let status = AudioObjectAddPropertyListenerBlock(sys, &address, queue, block)
        guard status == noErr else {
            Log.warn("Default-input-device listener failed: OSStatus \(status)")
            return
        }
        teardown = { [block, queue] in
            var a = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            _ = AudioObjectRemovePropertyListenerBlock(sys, &a, queue, block)
        }
    }

    deinit {
        listenerQueue.sync { }
        teardown?()
    }

    func currentDeviceId() -> AudioDeviceID? {
        CoreAudioActivityProvider.defaultInputDevice()
    }

    func observe(_ handler: @escaping () -> Void) -> DetectionToken {
        fanout.subscribe(handler)
    }

    private func notify() { fanout.notify() }
}
