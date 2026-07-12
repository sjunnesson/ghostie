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
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
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
