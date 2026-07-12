import Foundation

enum Log {
    private static let df: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let logFileURL: URL = {
        let dir = "\(NSHomeDirectory())/.ghostie"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: "\(dir)/ghostie.log")
    }()

    /// All file writes hop through one serial queue: Log.* is called from the
    /// engine's gate/work queues, the detector queue, SCK handler queues and
    /// the main thread, and unsynchronized appends interleave garbled lines.
    private static let queue = DispatchQueue(label: "ghostie.log", qos: .utility)

    /// One open handle for the process lifetime (reopened after rotation) —
    /// the old open-per-line pattern was 3 syscalls per log line.
    private static var handle: FileHandle?
    private static var bytesWritten: Int64 = -1   // -1 = size not yet read

    /// Rotate at ~5 MB: current log moves to ghostie.log.1 (previous .1 is
    /// dropped), so the app keeps at most ~10 MB of logs forever instead of
    /// growing without bound.
    private static let rotateAtBytes: Int64 = 5_000_000

    static func line(_ level: String, _ msg: String) {
        let stamp = df.string(from: Date())
        let text = "[\(stamp)] \(level) \(msg)"
        print(text)
        fflush(stdout)
        guard let data = (text + "\n").data(using: .utf8) else { return }
        queue.async { appendLocked(data) }
    }

    private static func appendLocked(_ data: Data) {
        if bytesWritten < 0 {
            bytesWritten = (try? FileManager.default
                .attributesOfItem(atPath: logFileURL.path)[.size] as? Int64).flatMap { $0 } ?? 0
        }
        if bytesWritten + Int64(data.count) > rotateAtBytes { rotateLocked() }
        if handle == nil {
            if !FileManager.default.fileExists(atPath: logFileURL.path) {
                FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
            }
            handle = try? FileHandle(forWritingTo: logFileURL)
            handle?.seekToEndOfFile()
        }
        guard let h = handle else { return }
        h.write(data)
        bytesWritten += Int64(data.count)
    }

    private static func rotateLocked() {
        try? handle?.close()
        handle = nil
        let fm = FileManager.default
        let old = logFileURL.appendingPathExtension("1")
        try? fm.removeItem(at: old)
        try? fm.moveItem(at: logFileURL, to: old)
        bytesWritten = 0
    }

    static func info(_ m: String)  { line("INFO ", m) }
    static func warn(_ m: String)  { line("WARN ", m) }
    static func error(_ m: String) { line("ERROR", m) }
    static func ok(_ m: String)    { line("OK   ", m) }
}
