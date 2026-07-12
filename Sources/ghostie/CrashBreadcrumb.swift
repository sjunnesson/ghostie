import Foundation
import Darwin

/// Local-only crash breadcrumb — NOT a crash reporter and NOT telemetry
/// (nothing ever leaves the machine; Ghostie's zero-egress posture stands).
/// A background agent that dies mid-call used to leave no trace at all: the
/// orphan sweep recovered the recording, but the *fact* that the previous
/// session crashed was invisible. This appends one line (plus a raw
/// backtrace) to `~/.ghostie/crash.log` on fatal signals and uncaught
/// exceptions, and warns on the next launch when the file grew.
///
/// Signal-path safety: the fd is pre-opened and the per-signal lines are
/// pre-rendered at install time, so the handler only does `write(2)`,
/// `backtrace_symbols_fd` (explicitly designed for this — no malloc), and
/// `raise`. Iterating the small pre-built array is the one Swiftism kept —
/// best-effort by design, per the "breadcrumb, not crash reporter" bar.
enum CrashBreadcrumb {
    static let path = "\(NSHomeDirectory())/.ghostie/crash.log"
    private static let seenPath = "\(NSHomeDirectory())/.ghostie/.crash.log.seen"
    private static let signals: [Int32] = [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGFPE, SIGTRAP]

    private static var fd: Int32 = -1
    /// Pre-rendered "[<session start>] crash: signal N (NAME)\n" per signal.
    /// `Data` keeps the bytes alive for the process lifetime; the handler
    /// reads the raw pointers only.
    private static var lines: [(sig: Int32, bytes: [UInt8])] = []

    static func install() {
        warnIfPreviousCrashLocked()
        try? FileManager.default.createDirectory(
            atPath: "\(NSHomeDirectory())/.ghostie", withIntermediateDirectories: true)
        fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }

        let stamp = ISO8601DateFormatter().string(from: Date())
        lines = signals.map { sig in
            let name = String(cString: strsignal(sig))
            return (sig, Array("[session \(stamp)] crash: signal \(sig) (\(name))\n".utf8))
        }

        // Uncaught ObjC/Swift exception: not a signal context, so normal
        // formatting is fine here.
        NSSetUncaughtExceptionHandler { ex in
            let msg = "[\(ISO8601DateFormatter().string(from: Date()))] crash: uncaught exception "
                + "\(ex.name.rawValue): \(ex.reason ?? "no reason")\n"
                + ex.callStackSymbols.prefix(10).joined(separator: "\n") + "\n"
            let bytes = Array(msg.utf8)
            bytes.withUnsafeBufferPointer { _ = write(CrashBreadcrumb.fd, $0.baseAddress, $0.count) }
        }

        for sig in signals { signal(sig, Self.handler) }
    }

    private static let handler: @convention(c) (Int32) -> Void = { sig in
        let fd = CrashBreadcrumb.fd
        if fd >= 0 {
            for entry in CrashBreadcrumb.lines where entry.sig == sig {
                entry.bytes.withUnsafeBufferPointer {
                    _ = write(fd, $0.baseAddress, $0.count)
                }
            }
            // backtrace_symbols_fd writes straight to the fd — no malloc.
            withUnsafeTemporaryAllocation(of: UnsafeMutableRawPointer?.self, capacity: 32) { stack in
                let n = backtrace(stack.baseAddress, 32)
                if n > 0 { backtrace_symbols_fd(stack.baseAddress, n, fd) }
            }
        }
        // Restore default and re-raise so the process still dies with the
        // real signal (crash logs, exit status, launchd restart all intact).
        signal(sig, SIG_DFL)
        raise(sig)
    }

    /// Compare crash.log's size against the size recorded last launch; a
    /// growth means the previous session died hard. Runs before install()
    /// opens the append fd.
    private static func warnIfPreviousCrashLocked() {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? Int64).flatMap { $0 } ?? 0
        let seen = (try? String(contentsOfFile: seenPath, encoding: .utf8))
            .flatMap { Int64($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        if size > seen {
            Log.warn("Previous session ended in a crash — see \(path)")
        }
        try? "\(size)".write(toFile: seenPath, atomically: true, encoding: .utf8)
    }
}
