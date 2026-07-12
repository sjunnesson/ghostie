import Foundation

/// Durable queue of recordings/transcripts that couldn't be fully processed
/// (whisper not set up, Claude Code not logged in, offline, …). Entries are
/// drained automatically once Ghostie can process again, so a captured call is
/// never lost just because a dependency was temporarily unavailable. Even an
/// entry that exhausts its retries is never deleted: `giveUp` moves it to
/// `given-up/`, out of the queue but intact for a manual `ghostie process <dir>`.
///
/// Layout: `~/.ghostie/backlog/<yyyy-MM-dd_HH-mm-ss>/`
///   meta.json                     — startedAt, duration, stage, attempts
///   me.wav / participants.wav     — present when stage == "transcribe"
///   transcript.md                 — present when stage == "summarize"
/// `~/.ghostie/backlog/given-up/<yyyy-MM-dd_HH-mm-ss>/` — same shape; retries
///   exhausted, skipped by `entries()` and `isEmpty`, kept for manual retry.
enum Backlog {
    static let root = "\(NSHomeDirectory())/.ghostie/backlog"
    static let givenUpDirName = "given-up"
    static let quarantineDirName = "quarantine"
    /// Entries whose meta.json is missing/undecodable are moved here — visibly,
    /// with a log line — instead of being silently skipped forever. Only dirs
    /// untouched for this long are quarantined, so an enqueue that is mid-write
    /// on another thread can never be swept out from under itself.
    static let quarantineAfterSeconds: TimeInterval = 120
    /// `given-up/` keeps failed entries (often with full audio) for manual
    /// retry. Unbounded, that grows forever — cap the total and prune the
    /// oldest beyond it, loudly.
    static let givenUpCapBytes: Int64 = 5_000_000_000

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
            // Atomic: a crash or full disk mid-write must not leave a
            // truncated meta.json — an undecodable entry drops out of the
            // queue (quarantined, at best) instead of being retried.
            try? data.write(to: dir.appendingPathComponent("meta.json"),
                            options: .atomic)
        }
    }

    /// Move `dir` under `root/<subdir>/`, de-duping the destination name on
    /// collision. Shared by `giveUp` and the quarantine path.
    private static func preserve(_ dir: URL, under subdir: String) -> URL? {
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: root).appendingPathComponent(subdir)
        try? fm.createDirectory(at: parent, withIntermediateDirectories: true)
        var dst = parent.appendingPathComponent(dir.lastPathComponent)
        var n = 2
        while fm.fileExists(atPath: dst.path) {
            dst = parent.appendingPathComponent("\(dir.lastPathComponent)-\(n)")
            n += 1
        }
        do {
            try fm.moveItem(at: dir, to: dst)
            return dst
        } catch {
            Log.error("Backlog: could not preserve \(dir.lastPathComponent) under \(subdir)/: \(error.localizedDescription)")
            return nil
        }
    }

    /// Queue a recording whose transcription failed (keeps the audio). Pass
    /// `copyingOriginals: true` to copy the WAVs instead of moving them, so a
    /// `keepAudio` user's retained session copy stays in place even after the
    /// backlog entry is eventually processed and removed.
    static func enqueueAudio(micWav: URL, systemWav: URL,
                             startedAt: Date, durationMins: String,
                             copyingOriginals: Bool = false) {
        ensureRoot()
        let dir = URL(fileURLWithPath: root)
            .appendingPathComponent(stamp.string(from: startedAt))
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fm = FileManager.default
        for (src, name) in [(micWav, "me.wav"), (systemWav, "participants.wav")] {
            let dst = dir.appendingPathComponent(name)
            try? fm.removeItem(at: dst)
            if fm.fileExists(atPath: src.path) {
                if copyingOriginals {
                    try? fm.copyItem(at: src, to: dst)
                } else {
                    try? fm.moveItem(at: src, to: dst)
                }
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

    /// Retries exhausted: take the entry out of the queue WITHOUT deleting it.
    /// The directory moves to `given-up/` unchanged (audio or transcript
    /// intact), so `entries()` and `isEmpty` stop seeing it but
    /// `ghostie process <dir>` can still consume it manually. Returns the
    /// preserved directory, or nil if the move failed — the entry then stays
    /// queued and the next drain retries the move.
    static func giveUp(_ entry: Entry) -> URL? {
        preserve(entry.dir, under: givenUpDirName)
    }

    /// Bound `given-up/` to `givenUpCapBytes` total: prune the OLDEST entries
    /// (they've already failed `Pipeline.maxAttempts` retries and have sat
    /// unclaimed the longest) until the newest fit under the cap. Deletion is
    /// logged per entry — this is the only place backlog data is ever
    /// destroyed. Called from `Pipeline.drain`.
    static func pruneGivenUp(capBytes: Int64 = givenUpCapBytes) {
        let fm = FileManager.default
        let parent = URL(fileURLWithPath: root).appendingPathComponent(givenUpDirName)
        guard let dirs = try? fm.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        func dirSize(_ d: URL) -> Int64 {
            (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.fileSizeKey]))?
                .compactMap { Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
                .reduce(0, +) ?? 0
        }
        // Entry dirs are stamped yyyy-MM-dd_HH-mm-ss, so name order is age order.
        let sized = dirs
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }   // newest first
            .map { (dir: $0, bytes: dirSize($0)) }
        var kept: Int64 = 0
        for e in sized {
            kept += e.bytes
            if kept > capBytes {
                Log.warn("Backlog: pruning given-up entry \(e.dir.lastPathComponent) (\(mbString(e.bytes))) — given-up/ exceeded \(mbString(capBytes)).")
                try? fm.removeItem(at: e.dir)
            }
        }
    }

    /// Pending entries, oldest first. A directory whose meta.json is missing
    /// or undecodable is NOT silently skipped: once it has sat untouched for
    /// `quarantineAfterSeconds` (so a mid-write enqueue is never swept), it is
    /// moved to `quarantine/` with a loud log so the user can inspect it —
    /// invisible-forever entries were the old failure mode.
    static func entries() -> [Entry] {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: nil) else { return [] }
        var result: [Entry] = []
        for d in dirs {
            var isDir: ObjCBool = false
            guard d.lastPathComponent != givenUpDirName,     // preserved, never retried
                  d.lastPathComponent != quarantineDirName,  // undecodable, kept visible
                  FileManager.default.fileExists(atPath: d.path, isDirectory: &isDir),
                  isDir.boolValue
            else { continue }
            guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")),
                  let meta = try? JSONDecoder().decode(Meta.self, from: data)
            else {
                quarantineIfStale(d)
                continue
            }
            result.append(Entry(dir: d, meta: meta))
        }
        return result.sorted { $0.meta.startedAt < $1.meta.startedAt }
    }

    private static func quarantineIfStale(_ dir: URL) {
        let age = -((try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSinceNow ?? 0)
        guard age > quarantineAfterSeconds else { return }
        if let dst = preserve(dir, under: quarantineDirName) {
            Log.warn("Backlog: entry \(dir.lastPathComponent) has no readable meta.json — moved to \(dst.path) for inspection. Re-queue with `ghostie process \"\(dst.path)\"` if the audio/transcript is intact.")
        }
    }

    static var pendingCount: Int { entries().count }

    /// Cheap emptiness probe for the periodic retry timer: a single directory
    /// listing, no meta.json reads or JSON parsing. Every entry lives in its
    /// own subdirectory, so "no subdirectories besides `given-up/` and
    /// `quarantine/`" is exactly "nothing pending" — both preserved folders
    /// are kept indefinitely and must not keep the probe reporting non-empty.
    /// (A stray non-entry subdirectory at worst costs one full `entries()`
    /// pass, which then ignores it as before.)
    static var isEmpty: Bool {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.isDirectoryKey]) else { return true }
        return !items.contains {
            $0.lastPathComponent != givenUpDirName
                && $0.lastPathComponent != quarantineDirName
                && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }
}
