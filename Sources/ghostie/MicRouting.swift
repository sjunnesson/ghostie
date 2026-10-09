import CoreAudio
import Foundation
import IOKit

/// Which microphone a call is recorded from.
///
/// Both capture paths record the **system default input**, and only that:
/// Apple's voice-processing unit ignores `kAudioOutputUnitProperty_CurrentDevice`
/// (measured 2026-10-01: bound to a live RØDE NT-USB Mini it delivered no
/// buffers at all; with the RØDE made the default it delivered 5 ch of signal
/// at once). So picking a microphone means making it the default for the call.
///
/// That is how the 2026-10-01 Teams call lost its whole "Me" track: the lid
/// was closed, the default input was still the MacBook Pro Microphone — which
/// a closed lid disconnects in hardware, so it opens normally and delivers
/// exact zeros — and Teams was talking to the RØDE because the user had
/// chosen it in Teams' own device settings. Both of Ghostie's paths recorded
/// the dead built-in mic for 29 minutes.
///
/// `decide` is pure (pinned in selftest); `MicRouter` does the CoreAudio side.
struct InputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: UInt32
    /// Has output channels too — a headset, or a USB mic with a headphone
    /// jack. Webcams are typically input-only, so this is the tiebreak that
    /// puts a real microphone ahead of the camera's.
    let hasOutput: Bool
    /// Some process has the device open — during a call, the call app's mic.
    let isRunningSomewhere: Bool

    var isBuiltIn: Bool { transport == kAudioDeviceTransportTypeBuiltIn }
    /// Loopback drivers ("Microsoft Teams Audio", BlackHole) and aggregates
    /// carry other audio, not a voice.
    var isVirtual: Bool {
        transport == kAudioDeviceTransportTypeVirtual
            || transport == kAudioDeviceTransportTypeAggregate
            || transport == kAudioDeviceTransportTypeAutoAggregate
    }
    /// An iPhone used as a Continuity microphone: real, but rarely the mic
    /// the user meant, and it can walk out of the room.
    var isContinuity: Bool {
        transport == kAudioDeviceTransportTypeContinuityCaptureWired
            || transport == kAudioDeviceTransportTypeContinuityCaptureWireless
    }
}

enum MicRoute: Equatable {
    /// Record the system default as it is.
    case systemDefault
    /// Make this device the default input for the call.
    case switchTo(InputDevice, because: Reason)
    /// The default is the built-in mic, the lid is closed, and there is no
    /// other microphone to switch to. The "Me" track will be silent.
    case noWorkingMic

    enum Reason: Equatable {
        /// The user picked it in Settings ▸ Listening.
        case chosen
        /// The default is the built-in mic and the lid is closed.
        case lidClosed
    }

    /// The decision. `preferredUID` empty means "System default".
    ///
    /// A chosen device wins whenever it is connected and can work. Otherwise
    /// the default stands — unless it is the built-in mic under a closed lid,
    /// in which case the best other microphone is used: the one the call app
    /// already has open, then a non-iPhone one, then one with an output (a
    /// headset or a USB mic rather than a webcam), then by transport.
    static func decide(preferredUID: String, devices: [InputDevice],
                       defaultID: AudioDeviceID?, lidClosed: Bool) -> MicRoute {
        func works(_ d: InputDevice) -> Bool { !(d.isBuiltIn && lidClosed) }

        if !preferredUID.isEmpty,
           let chosen = devices.first(where: { $0.uid == preferredUID }), works(chosen) {
            return chosen.id == defaultID ? .systemDefault : .switchTo(chosen, because: .chosen)
        }
        guard let current = devices.first(where: { $0.id == defaultID }),
              !works(current) else { return .systemDefault }

        let candidates = devices.filter { !$0.isBuiltIn && !$0.isVirtual }
        guard let best = candidates.min(by: { rank($0) < rank($1) }) else { return .noWorkingMic }
        return .switchTo(best, because: .lidClosed)
    }

    private static func rank(_ d: InputDevice) -> (Int, Int, Int, Int, String) {
        (d.isRunningSomewhere ? 0 : 1,
         d.isContinuity ? 1 : 0,
         d.hasOutput ? 0 : 1,
         transportRank(d.transport),
         d.name)
    }

    private static func transportRank(_ t: UInt32) -> Int {
        switch t {
        case kAudioDeviceTransportTypeUSB: return 0
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return 1
        default: return 2
        }
    }

    /// Whether `restore` may put `previous` back: only if it would work now.
    /// A lid-closed switch is undone only once the lid has been opened —
    /// otherwise the next call would walk straight back into the dead mic.
    static func canRestore(previous: InputDevice?, lidClosed: Bool) -> Bool {
        guard let previous else { return false }
        return !(previous.isBuiltIn && lidClosed)
    }
}

/// Where the far end comes out, as far as echo is concerned.
///
/// Voice processing cancels whatever the default output plays — except
/// through the Mac's **built-in headphone jack**, which it takes for
/// headphones: echo cancellation off, automatic gain on. Desk speakers on that
/// jack are exactly what it cannot see (measured 2026-10-06 with a RØDE 20 cm
/// from them: raw mic −38.5 dBFS of echo, voice-processed −24 — louder; the
/// MacBook's own speakers: −34.5 raw, −49 voice-processed). So on that route
/// the recorder takes the raw mic and `EchoCanceller` does the cancelling.
/// Real headphones on the jack lose nothing by it: there is no echo to cancel.
enum OutputRoute {
    /// CoreAudio's data source code for the built-in headphone port, `'hdpn'`
    /// (the MacBook's speakers report `'ispk'`).
    static let headphonePort: UInt32 = 0x6864_706E

    static func voiceProcessingCancelsEcho(transport: UInt32, dataSource: UInt32?) -> Bool {
        !(transport == kAudioDeviceTransportTypeBuiltIn && dataSource == headphonePort)
    }
}

/// The CoreAudio side of `MicRoute`.
enum MicRouter {

    /// The default output's name, and whether voice processing will cancel
    /// echo through it (`OutputRoute`). nil when there is no default output.
    static func defaultOutput() -> (name: String, voiceProcessingCancelsEcho: Bool)? {
        let id = uint32(AudioObjectID(kAudioObjectSystemObject),
                        kAudioHardwarePropertyDefaultOutputDevice)
        guard id != kAudioObjectUnknown else { return nil }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                              mScope: kAudioObjectPropertyScopeOutput,
                                              mElement: kAudioObjectPropertyElementMain)
        var source: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let hasSource = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &source) == noErr
        let cancels = OutputRoute.voiceProcessingCancelsEcho(
            transport: uint32(id, kAudioDevicePropertyTransportType),
            dataSource: hasSource ? source : nil)
        return (string(id, kAudioObjectPropertyName) ?? "the default output", cancels)
    }

    /// What `apply` changed, so `restore` can undo exactly that and nothing
    /// the user did in the meantime.
    struct Switch {
        let previous: AudioDeviceID
        let to: InputDevice
        let reason: MicRoute.Reason
    }

    /// Decides and, if needed, switches the default input. Logs either way.
    static func apply(preferredUID: String) -> (route: MicRoute, switched: Switch?) {
        let devices = inputDevices()
        let defaultID = defaultInput()
        let lid = isLidClosed()
        if !preferredUID.isEmpty, !devices.contains(where: { $0.uid == preferredUID }) {
            Log.warn("Mic: the microphone chosen in Settings isn't connected — recording the system default instead.")
        }
        let route = MicRoute.decide(preferredUID: preferredUID, devices: devices,
                                    defaultID: defaultID, lidClosed: lid)
        let currentName = devices.first(where: { $0.id == defaultID })?.name ?? "none"
        switch route {
        case .systemDefault:
            return (route, nil)
        case .noWorkingMic:
            Log.error("Mic: the lid is closed, so the built-in microphone is switched off, and no other microphone is connected — your side of this call will not be recorded.")
            return (route, nil)
        case .switchTo(let device, let reason):
            let why = reason == .lidClosed
                ? "the lid is closed, which switches \(currentName) off"
                : "it is the microphone chosen in Settings"
            guard let previous = defaultID, setDefaultInput(device.id) else {
                Log.error("Mic: could not make \(device.name) the input device (\(why)) — recording \(currentName).")
                return (.systemDefault, nil)
            }
            Log.info("Mic: recording from \(device.name) instead of \(currentName) — \(why).")
            return (route, Switch(previous: previous, to: device, reason: reason))
        }
    }

    /// Puts the default input back after the call, unless the user changed
    /// it since, or the old device would not work now.
    static func restore(_ s: Switch) {
        guard defaultInput() == s.to.id else {
            Log.info("Mic: the input device changed during the call — leaving it as it is.")
            return
        }
        let previous = inputDevices().first(where: { $0.id == s.previous })
        guard MicRoute.canRestore(previous: previous, lidClosed: isLidClosed()),
              let previous else {
            Log.info("Mic: keeping \(s.to.name) as the input device — the previous one would not work now.")
            return
        }
        if setDefaultInput(previous.id) {
            Log.info("Mic: input device restored to \(previous.name).")
        }
    }

    // MARK: CoreAudio / IOKit

    static func inputDevices() -> [InputDevice] {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr,
              size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard channels(id, kAudioObjectPropertyScopeInput) > 0,
                  let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return InputDevice(
                id: id, uid: uid,
                name: string(id, kAudioObjectPropertyName) ?? uid,
                transport: uint32(id, kAudioDevicePropertyTransportType),
                hasOutput: channels(id, kAudioObjectPropertyScopeOutput) > 0,
                isRunningSomewhere: uint32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) != 0)
        }
    }

    static func defaultInput() -> AudioDeviceID? {
        let id = uint32(AudioObjectID(kAudioObjectSystemObject),
                        kAudioHardwarePropertyDefaultInputDevice)
        return id == kAudioObjectUnknown ? nil : id
    }

    @discardableResult
    static func setDefaultInput(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value = id
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &value) == noErr
    }

    /// A MacBook's lid is closed (running on an external display). False on
    /// a desktop Mac, which has no such key.
    static func isLidClosed() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { return false }
        defer { IOObjectRelease(root) }
        let value = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString,
                                                    kCFAllocatorDefault, 0)?.takeRetainedValue()
        return (value as? Bool) ?? false
    }

    private static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : 0
    }

    private static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr,
              let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channels(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                              mScope: scope,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                   alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
