import Foundation

/// Cross-track echo guard.
///
/// The system-audio track ("Participants") is what Teams plays out — it can
/// never contain the local microphone. The reverse is not true: without
/// headphones (or when AEC is unavailable) the speakers' output re-enters the
/// mic, so the "Me" track transcribes the other participants a second time,
/// interleaved 1–2 s off the genuine copy. `TranscriptCleaner` runs per track
/// and is structurally blind to this, so the guard runs between the per-track
/// clean and the timestamp merge: any run of words on Me that also appears on
/// Participants nearby is echo, and only the Me copy is ever trimmed.
///
/// Deliberately conservative:
///   • it only engages when duplication is endemic (echo calls), so headphone
///     users — where a cross-track match is genuine verbal mirroring — are
///     never touched;
///   • within an engaged call, only runs of ≥ `minRun` words are trimmed, so
///     shared backchannels ("yeah exactly") survive.
/// Known cost: on an echo call, one speaker genuinely repeating the other's
/// sentence verbatim within the window loses the Me copy. The content always
/// survives on Participants; only that line's attribution is lost.
enum EchoSuppressor {

    struct Stats {
        var engaged = false
        /// Percentage of Me words that duplicate Participants nearby.
        var coveragePercent = 0
        var dropped = 0
        var trimmed = 0
        var summary: String {
            engaged
                ? "echo guard: engaged (\(coveragePercent)% of 'Me' duplicated 'Participants') — \(dropped) echoed segments dropped, \(trimmed) trimmed"
                : "echo guard: not engaged (\(coveragePercent)% cross-track overlap)"
        }
    }

    /// A Participants segment is a candidate echo source for a Me segment when
    /// the Me start lies within this margin of the Participants segment's
    /// *span* (start … estimated end). Real echo is physically simultaneous;
    /// the margin absorbs whisper segmenting the two tracks differently
    /// (observed up to ~3 s either way on real calls). Spans matter because
    /// whisper sometimes packs a 30 s monologue into ONE Participants segment
    /// while the mic echo of its tail lands 20+ s after that segment's start.
    private static let windowMs = 8_000
    /// A segment's end is estimated as the next same-track segment's start,
    /// capped at this — a lone segment before a long silence must not claim
    /// the silence as its span.
    private static let maxSpanMs = 45_000
    /// Minimum matched word run that counts as echo. Below this, identical
    /// wording across tracks is routine conversational overlap.
    private static let minRun = 5
    /// Engage only when at least this fraction of Me words is duplicated —
    /// echo is endemic or absent, never occasional.
    private static let engageCoverage = 0.25
    /// …and only when the track is big enough for the fraction to mean much.
    private static let engageMinWords = 100
    /// After trimming, a segment keeping less than this fraction of its words
    /// (or fewer than `minMeaningfulKept` non-filler words) is residue of an
    /// imperfect echo decode ("like there's this overall deconnection") — drop
    /// it rather than leave a garbled stub.
    private static let keepFractionFloor = 0.4
    private static let minMeaningfulKept = 3

    private static let fillerWords: Set<String> = [
        "yeah", "yes", "yep", "no", "okay", "ok", "uh", "um", "hmm", "mm",
        "mhm", "mm-hmm", "so", "right", "exactly", "sure", "and", "like"
    ]

    private struct Token {
        let original: String
        let norm: String
    }

    private static let strippable = CharacterSet(charactersIn: ".,!?;:…\"'’‘“”()[]-—")

    private static func tokenize(_ text: String) -> [Token] {
        text.split(separator: " ", omittingEmptySubsequences: true).map {
            let original = String($0)
            let norm = original.lowercased()
                .trimmingCharacters(in: strippable)
            return Token(original: original, norm: norm)
        }
    }

    /// Removes echoed content from `me`; `participants` is authoritative and
    /// never modified (physics: system audio cannot contain the mic).
    /// Pure and deterministic — same input, same output.
    static func suppress(me: [(startMs: Int, text: String)],
                         participants: [(startMs: Int, text: String)])
        -> (me: [(startMs: Int, text: String)], stats: Stats) {
        var stats = Stats()
        guard !me.isEmpty, !participants.isEmpty else { return (me, stats) }

        let meTokens = me.map { tokenize($0.text) }
        let partTokens = participants.map { tokenize($0.text) }
        let partEnds = participants.indices.map { j in
            let next = j + 1 < participants.count
                ? participants[j + 1].startMs : Int.max
            return min(next, participants[j].startMs + maxSpanMs)
        }

        // Pass 1: mark every Me word that sits inside a ≥minRun run shared
        // with a nearby Participants segment.
        var marks: [[Bool]] = meTokens.map { [Bool](repeating: false, count: $0.count) }
        var totalWords = 0
        var matchedWords = 0
        for (i, a) in meTokens.enumerated() {
            guard !a.isEmpty else { continue }
            let start = me[i].startMs
            var b: [Token] = []
            for (j, p) in participants.enumerated()
            where start >= p.startMs - windowMs && start <= partEnds[j] + windowMs {
                b.append(contentsOf: partTokens[j])
            }
            if !b.isEmpty { markCommonRuns(a: a, b: b, marks: &marks[i]) }
            for (k, t) in a.enumerated() where !t.norm.isEmpty {
                totalWords += 1
                if marks[i][k] { matchedWords += 1 }
            }
        }

        stats.coveragePercent = totalWords == 0
            ? 0 : Int((Double(matchedWords) / Double(totalWords) * 100).rounded())
        guard totalWords >= engageMinWords,
              Double(matchedWords) / Double(totalWords) >= engageCoverage else {
            return (me, stats)
        }
        stats.engaged = true

        // Pass 2: rebuild Me from the unmarked words.
        var out: [(startMs: Int, text: String)] = []
        for (i, seg) in me.enumerated() {
            let a = meTokens[i]
            let kept = a.indices.filter { !marks[i][$0] }
            if kept.count == a.count {
                out.append(seg)
                continue
            }
            let meaningful = kept.filter {
                !a[$0].norm.isEmpty && !fillerWords.contains(a[$0].norm)
            }.count
            if kept.isEmpty
                || meaningful < minMeaningfulKept
                || Double(kept.count) / Double(a.count) < keepFractionFloor {
                stats.dropped += 1
                continue
            }
            stats.trimmed += 1
            out.append((startMs: seg.startMs,
                        text: kept.map { a[$0].original }.joined(separator: " ")))
        }
        return (out, stats)
    }

    /// Marks positions of `a` covered by any common consecutive-word run of
    /// length ≥ `minRun` shared with `b`. Classic longest-common-substring DP
    /// over normalized words; punctuation-only tokens (empty norm) never match
    /// so they break runs.
    private static func markCommonRuns(a: [Token], b: [Token], marks: inout [Bool]) {
        var prev = [Int](repeating: 0, count: b.count)
        for i in a.indices {
            var cur = [Int](repeating: 0, count: b.count)
            let an = a[i].norm
            if !an.isEmpty {
                for j in b.indices where b[j].norm == an {
                    let run = (j == 0 ? 0 : prev[j - 1]) + 1
                    cur[j] = run
                    if run >= minRun {
                        for k in (i - run + 1)...i { marks[k] = true }
                    }
                }
            }
            prev = cur
        }
    }
}
