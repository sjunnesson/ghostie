import Foundation

/// Monotonic seconds since some arbitrary epoch. Only relative differences
/// matter — never serialize a `VirtualTime` as a wall-clock date (anything
/// user-facing, like diagnose-detect's `ts` field, uses `Date()` separately).
typealias VirtualTime = TimeInterval

/// Time source the state machine and providers query. SystemClock in production,
/// VirtualClock in tests so we can scrub time without sleeping.
protocol Clock: AnyObject {
    var now: VirtualTime { get }
}

/// Production clock, backed by `CLOCK_UPTIME_RAW`, which is genuinely
/// monotonic: an NTP step never jumps it (unlike `CFAbsoluteTimeGetCurrent`,
/// which is wall-clock and would stretch or shorten the confirm/grace
/// windows), and it does **not** tick while the machine sleeps. For the
/// detector's windows the sleep behavior is deliberate: closing the lid
/// mid-call must not silently burn the 30 s end grace while asleep, so the
/// call is still recoverable on wake. Values are seconds since boot — they
/// have no meaning across processes or reboots.
final class SystemClock: Clock {
    var now: VirtualTime {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }
}

/// Deterministic clock for selftests. Time only advances when callers ask.
final class VirtualClock: Clock {
    private var _now: VirtualTime

    init(start: VirtualTime = 0) { _now = start }

    var now: VirtualTime { _now }

    func advance(by seconds: TimeInterval) {
        precondition(seconds >= 0, "VirtualClock does not go backwards")
        _now += seconds
    }
}
