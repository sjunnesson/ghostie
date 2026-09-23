import Foundation

// Shared process + byte-formatting helpers. One definition each; previously
// copy-pasted across Updater, ModelDownloader, main.swift and Config.

/// Run a process and capture stdout(+stderr) as one string. The pipe is
/// drained to EOF *before* `waitUntilExit` so output larger than the pipe
/// buffer cannot deadlock the child.
@discardableResult
func runProcess(_ path: String, _ args: [String],
                stderrToNull: Bool = false) -> (status: Int32, output: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = stderrToNull ? FileHandle.nullDevice : pipe
    do { try p.run() } catch { return (-1, "") }
    ChildProcesses.register(p)
    defer { ChildProcesses.unregister(p) }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// A watched child that outlived its budget and was killed.
struct ProcessTimedOut: LocalizedError {
    let name: String
    let seconds: TimeInterval
    var errorDescription: String? {
        "\(name) was still running after \(Int(seconds)) s and was terminated — it looked hung."
    }
}

/// Run an already-configured `Process` (executable, arguments, environment,
/// cwd) to completion with a deadline, capturing stdout+stderr.
///
/// The output is drained on its own queue while the child runs, so neither a
/// full pipe nor a hung child can wedge the caller: at `timeout` the child
/// gets SIGTERM, two seconds, then SIGKILL, and this throws
/// `ProcessTimedOut`. whisper-cli used to be waited on with no deadline at
/// all — one hung decode (a Metal stall) blocked the serial pipeline queue
/// for good, and every later call queued behind it.
func runWatched(_ p: Process, timeout: TimeInterval) throws -> (status: Int32, output: String) {
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try p.run()
    ChildProcesses.register(p)
    defer { ChildProcesses.unregister(p) }

    var data = Data()
    let drained = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        data = pipe.fileHandleForReading.readDataToEndOfFile()
        drained.signal()
    }
    let exited = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async { p.waitUntilExit(); exited.signal() }

    if exited.wait(timeout: .now() + timeout) == .timedOut {
        ChildProcesses.stop(p)
        _ = exited.wait(timeout: .now() + 2)
        _ = drained.wait(timeout: .now() + 2)
        throw ProcessTimedOut(name: p.executableURL?.lastPathComponent ?? "process",
                              seconds: timeout)
    }
    // Exited; EOF follows at once unless a stray grandchild inherited the fd.
    _ = drained.wait(timeout: .now() + 10)
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

/// Every child Ghostie is currently waiting on, so quitting can take them
/// down: a Foundation `Process` outlives its parent on macOS, and a quit
/// mid-pipeline used to leave whisper-cli or `claude -p` running to the end
/// of its work — while the relaunched app transcribed the same audio again.
enum ChildProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var live: [ObjectIdentifier: Process] = [:]
    nonisolated(unsafe) private static var quitting = false

    /// True once `terminateAll()` has run for a quit. The pipeline reads it to
    /// tell "the child was killed because we are quitting" from a real
    /// failure: the former must leave the session to the next launch's sweep,
    /// not count a failed attempt or queue a half-finished result.
    static var isQuitting: Bool { lock.withLock { quitting } }

    static func register(_ p: Process) {
        lock.withLock { live[ObjectIdentifier(p)] = p }
    }

    static func unregister(_ p: Process) {
        lock.withLock { _ = live.removeValue(forKey: ObjectIdentifier(p)) }
    }

    /// SIGTERM, a two-second grace, then SIGKILL.
    static func stop(_ p: Process) {
        guard p.isRunning else { return }
        p.terminate()
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    /// Stop every registered child (all at once, then wait out the grace).
    static func terminateAll() {
        let all = lock.withLock { () -> [Process] in
            quitting = true
            return Array(live.values)
        }
        guard !all.isEmpty else { return }
        Log.info("Stopping \(all.count) child process(es) before quitting.")
        all.forEach { if $0.isRunning { $0.terminate() } }
        let deadline = Date().addingTimeInterval(2)
        while all.contains(where: \.isRunning) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        all.filter(\.isRunning).forEach { kill($0.processIdentifier, SIGKILL) }
    }
}

/// A value behind its own lock, for the odd flag shared across queues.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock(); defer { lock.unlock() }
        return body(&value)
    }
}

/// "1.1 GB" / "512 MB" / "885 KB" — progress-line byte formatting.
func mbString(_ b: Int64) -> String {
    if b >= 10_000_000_000 { return "\(b / 1_000_000_000) GB" }
    if b >= 1_000_000_000 { return String(format: "%.1f GB", Double(b) / 1_000_000_000) }
    return b >= 1_000_000 ? "\(b / 1_000_000) MB" : "\(max(0, b) / 1000) KB"
}

/// Free bytes on the volume holding `path` (importance-weighted capacity, so
/// purgeable space counts), or nil when the volume can't be queried.
func freeDiskBytes(at path: String) -> Int64? {
    let url = URL(fileURLWithPath: path)
    guard let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
          let free = v.volumeAvailableCapacityForImportantUsage else { return nil }
    return free
}

/// Below this, recording + backlog writes are at real risk of silent
/// truncation (most writes are `try?`). Doctor fails and the recorder warns.
let lowDiskThresholdBytes: Int64 = 1_000_000_000
