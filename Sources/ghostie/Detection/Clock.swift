import Foundation

/// Monotonic seconds since some arbitrary epoch. Only relative differences matter.
typealias VirtualTime = TimeInterval

/// Time source the state machine and providers query. SystemClock in production,
/// VirtualClock in tests so we can scrub time without sleeping.
protocol Clock: AnyObject {
    var now: VirtualTime { get }
}

final class SystemClock: Clock {
    var now: VirtualTime { CFAbsoluteTimeGetCurrent() }
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
