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

    static func line(_ level: String, _ msg: String) {
        let stamp = df.string(from: Date())
        let text = "[\(stamp)] \(level) \(msg)"
        print(text)
        fflush(stdout)
        if let data = (text + "\n").data(using: .utf8) {
            if let h = try? FileHandle(forWritingTo: logFileURL) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: logFileURL)
            }
        }
    }

    static func info(_ m: String)  { line("INFO ", m) }
    static func warn(_ m: String)  { line("WARN ", m) }
    static func error(_ m: String) { line("ERROR", m) }
    static func ok(_ m: String)    { line("OK   ", m) }
}
