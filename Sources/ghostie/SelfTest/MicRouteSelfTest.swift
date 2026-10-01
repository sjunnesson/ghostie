import CoreAudio
import Foundation

/// Regression check for which microphone a call records (`MicRoute`).
///
/// The device list is the one on the desk during the 2026-10-01 Teams call:
/// lid closed, default input still the MacBook Pro Microphone (hardware-off,
/// so 29 minutes of exact zeros), a RØDE NT-USB Mini open in Teams, a
/// webcam, an iPhone, and Teams' own loopback driver.
func runMicRouteSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)\n      \(detail())") }
    }
    func dev(_ id: AudioDeviceID, _ name: String, _ transport: UInt32,
             output: Bool = false, running: Bool = false) -> InputDevice {
        InputDevice(id: id, uid: "uid-\(id)", name: name, transport: transport,
                    hasOutput: output, isRunningSomewhere: running)
    }
    let builtIn = dev(93, "MacBook Pro Microphone", kAudioDeviceTransportTypeBuiltIn)
    let rode = dev(98, "RØDE NT-USB Mini", kAudioDeviceTransportTypeUSB, output: true)
    let rodeInCall = dev(98, "RØDE NT-USB Mini", kAudioDeviceTransportTypeUSB, output: true, running: true)
    let webcam = dev(128, "Logitech StreamCam", kAudioDeviceTransportTypeUSB)
    let webcamInCall = dev(128, "Logitech StreamCam", kAudioDeviceTransportTypeUSB, running: true)
    let iphone = dev(147, "iPhone Microphone", kAudioDeviceTransportTypeContinuityCaptureWireless)
    let teamsLoop = dev(62, "Microsoft Teams Audio", kAudioDeviceTransportTypeVirtual,
                        output: true, running: true)
    let desk = [iphone, rode, webcam, builtIn, teamsLoop]

    func route(_ devices: [InputDevice], preferred: String = "",
               defaultID: AudioDeviceID? = 93, lid: Bool) -> MicRoute {
        MicRoute.decide(preferredUID: preferred, devices: devices,
                        defaultID: defaultID, lidClosed: lid)
    }

    // ---- The 2026-10-01 call.
    check("lid closed + built-in default → the RØDE, not the dead built-in mic",
          route(desk, lid: true) == .switchTo(rode, because: .lidClosed),
          "\(route(desk, lid: true))")
    check("the mic the call app has open beats the usual ranking",
          route([iphone, rode, webcamInCall, builtIn], lid: true)
            == .switchTo(webcamInCall, because: .lidClosed))
    check("a loopback driver is never picked, even when it is running",
          route([builtIn, teamsLoop], lid: true) == .noWorkingMic)
    check("a USB mic with an output beats an input-only webcam",
          route([webcam, builtIn, rode], lid: true) == .switchTo(rode, because: .lidClosed))
    check("an iPhone is a last resort, but better than nothing",
          route([builtIn, iphone], lid: true) == .switchTo(iphone, because: .lidClosed))
    check("lid closed with only the built-in mic → no working mic",
          route([builtIn], lid: true) == .noWorkingMic)

    // ---- Leave a working default alone.
    check("lid open → the built-in default is recorded as it is",
          route(desk, lid: false) == .systemDefault)
    check("lid closed but the default is already external → nothing to do",
          route(desk, defaultID: 98, lid: true) == .systemDefault)
    check("no default input at all → nothing to decide",
          route(desk, defaultID: nil, lid: true) == .systemDefault)

    // ---- A microphone chosen in Settings.
    check("chosen mic that isn't the default → switch to it",
          route(desk, preferred: "uid-128", lid: false) == .switchTo(webcam, because: .chosen))
    check("chosen mic that is already the default → nothing to do",
          route(desk, preferred: "uid-93", lid: false) == .systemDefault)
    check("chosen built-in mic under a closed lid → treated as unusable, RØDE instead",
          route(desk, preferred: "uid-93", lid: true) == .switchTo(rode, because: .lidClosed))
    check("chosen mic not connected → falls back to the default",
          route(desk, preferred: "uid-999", lid: false) == .systemDefault)
    check("chosen mic not connected, lid closed → still avoids the dead built-in mic",
          route([builtIn, rodeInCall], preferred: "uid-999", lid: true)
            == .switchTo(rodeInCall, because: .lidClosed))

    // ---- Putting the old default back after the call.
    check("restore the built-in mic once the lid is open again",
          MicRoute.canRestore(previous: builtIn, lidClosed: false))
    check("never restore the built-in mic under a closed lid",
          !MicRoute.canRestore(previous: builtIn, lidClosed: true))
    check("restore an external previous device whatever the lid does",
          MicRoute.canRestore(previous: webcam, lidClosed: true))
    check("a previous device that has gone away is not restored",
          !MicRoute.canRestore(previous: nil, lidClosed: false))

    print("MicRoute self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
