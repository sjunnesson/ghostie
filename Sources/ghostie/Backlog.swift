import Foundation

/// Durable queue of recordings/transcripts that couldn't be fully processed
/// (whisper not set up, Claude Code not logged in, offline, …). Entries are
/// drained automatically once Ghostie can process again, so a captured call is
/// never lost just because a dependency was temporarily unavailable.
///
/// Layout: `~/.ghostie/backlog/<yyyy-MM-dd_HH-mm-ss>/`
///   meta.json                     — startedAt, duration, stage, attempts
///   me.wav / participants.wav     — present when stage == "transcribe"
///   transcript.md                 — present when stage == "summarize"
enum Backlog {
    static let root = "\(NSHomeDirectory())/.ghostie/backlog"

    struct Meta: Codable {
        var startedAt: Double          // epoch seconds
        var durationMins: String
        var stage: String              // "transcribe" | "summarize"
        var attempts: Int
    }

    struct Entry {
        let dir: URL
        let meta: Meta
        var startedAtDate: Date { Date(timeIntervalSince1970: meta.startedAt) }
        var micWav: URL { dir.appendingPathComponent("me.wav") }
        var systemWav: URL { dir.appendingPathComponent("participants.wav") }
        var transcriptFile: URL { dir.appendingPathComponent("transcript.md") }
    }

    private static let stamp: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd_HH-mm-ss"; return f
    }()

    private static func ensureRoot() {
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    private static func writeMeta(_ meta: Meta, to dir: URL) {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(meta) {
            try? data.write(to: dir.appendingPathComponent("meta.json"))
        }
    }

    /// Queue a recording whose transcription failed (keeps the audio).
    static func enqueueAudio(micWav: URL, systemWav: URL,
                             startedAt: Date, durationMins: String) {
        ensureRoot()
        let dir = URL(fileURLWithPath: root)
            .appendingPathComponent(stamp.string(from: startedAt))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default
        for (src, name) in [(micWav, "me.wav"), (systemWav, "participants.wav")] {
            let dst = dir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            if fm.fileExists(atPath: src.path) {
                try? fm.moveItem(at: src, to: dst)
            }
        }
        writeMeta(Meta(startedAt: startedAt.timeIntervalSince1970,
                       durationMins: durationMins, stage: "transcribe",
                       attempts: 0), to: dir)
        Log.info("Queued recording to backlog (transcription pending): \(dir.lastPathComponent)")
    }

    /// Queue a finished transcript whose summary failed (audio not needed).
    static func enqueueTranscript(startedAt: Date, durationMins: String,
                                  transcript: String) {
        ensureRoot()
        let dir = URL(fileURLWithPath: root)
            .appendingPathComponent(stamp.string(from: startedAt))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? transcript.write(to: dir.appendingPathComponent("transcript.md"),
                              atomically: true, encoding: .utf8)
        writeMeta(Meta(startedAt: startedAt.timeIntervalSince1970,
                       durationMins: durationMins, stage: "summarize",
                       attempts: 0), to: dir)
        Log.info("Queued transcript to backlog (summary pending): \(dir.lastPathComponent)")
    }

    /// Transcription succeeded later but summary still can't run: keep the
    /// transcript, drop the audio, so we never re-transcribe this one again.
    static func convertToSummarize(_ entry: Entry, transcript: String) {
        try? transcript.write(to: entry.transcriptFile, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: entry.micWav)
        try? FileManager.default.removeItem(at: entry.systemWav)
        var m = entry.meta; m.stage = "summarize"; m.attempts = 0
        writeMeta(m, to: entry.dir)
    }

    static func bump(_ entry: Entry) {
        var m = entry.meta; m.attempts += 1
        writeMeta(m, to: entry.dir)
    }

    static func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.dir)
    }

    /// Pending entries, oldest first.
    static func entries() -> [Entry] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: nil) else { return [] }
        var result: [Entry] = []
        for d in dirs {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir),
                  isDir.boolValue,
                  let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")),
                  let meta = try? JSONDecoder().decode(Meta.self, from: data)
            else { continue }
            result.append(Entry(dir: d, meta: meta))
        }
        return result.sorted { $0.meta.startedAt < $1.meta.startedAt }
    }

    static var pendingCount: Int { entries().count }

    /// Cheap emptiness probe for the periodic retry timer: a single directory
    /// listing, no meta.json reads or JSON parsing. Every entry lives in its
    /// own subdirectory, so "no subdirectories" is exactly "nothing pending".
    /// (A stray non-entry subdirectory at worst costs one full `entries()`
    /// pass, which then ignores it as before.)
    static var isEmpty: Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey]) else { return true }
        return !items.contains {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
