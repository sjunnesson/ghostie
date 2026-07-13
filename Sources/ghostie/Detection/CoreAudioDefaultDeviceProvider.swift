import Foundation
import CoreAudio

/// Observes the system default input device (`kAudioHardwarePropertyDefaultInputDevice`)
/// AND the device list itself (`kAudioHardwarePropertyDevices`). The
/// coordinator uses change notifications to trigger a 3 s "quiescence pulse"
/// that prevents a transient primary-signal drop from collapsing a confirmed
/// call when the user, say, unplugs headphones mid-meeting.
///
/// The device-list listener is what covers calls on a NON-default device: a
/// hot-swap there never changes the default input, but the vanishing/
/// appearing device always changes the list — without it, such calls got no
/// quiescence and had to ride the plain 30 s end grace.
final class CoreAudioDefaultDeviceProvider: DefaultInputDeviceProvider {

    private let listenerQueue = DispatchQueue(label: "ghostie.defaultdevice")
    private let fanout = ChangeFanout()
    private var teardowns: [() -> Void] = []

    init() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.notify()
        }
        let queue = listenerQueue
        let sys = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyDefaultInputDevice,
                         kAudioHardwarePropertyDevices] {
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let status = AudioObjectAddPropertyListenerBlock(sys, &address, queue, block)
            guard status == noErr else {
                Log.warn("Audio-device listener (selector \(selector)) failed: OSStatus \(status)")
                continue
            }
            teardowns.append { [block, queue] in
                var a = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                _ = AudioObjectRemovePropertyListenerBlock(sys, &a, queue, block)
            }
        }
    }

    deinit {
        listenerQueue.sync { }
        teardowns.forEach { $0() }
    }

    func currentDeviceId() -> AudioDeviceID? {
        CoreAudioActivityProvider.defaultInputDevice()
    }

    func observe(_ handler: @escaping () -> Void) -> DetectionToken {
        fanout.subscribe(handler)
    }

    private func notify() { fanout.notify() }
}
