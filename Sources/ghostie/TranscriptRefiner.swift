import Foundation

/// Turns whisper's segment stream into readable turns. Two separate defects,
/// repaired in order.
///
/// **1 — turns.** whisper closes a segment every few seconds regardless of
/// where the sentence ends, and `Pipeline.merge` only sorts, so one sentence
/// arrives as three transcript lines:
///
///     [10:11] Jose: means in the first round you have at least 60 ideas and then we asked them to select one of
///     [10:20] Jose: ideas and then in order to like specify what that idea was um we also make this kind of like
///
/// `coalesce` joins consecutive same-speaker lines while the previous one
/// hasn't ended a sentence. Pure.
///
/// **2 — punctuation.** large-v3 drifts into a lowercase, unpunctuated
/// register and stays there for many minutes at a stretch (measured on the
/// 2026-08-28 call: 12% of turns ended in terminal punctuation, against 96%
/// for a reference recording of the same conversation; the longest unbroken
/// run was 83 lines). This reproduces with plain `whisper-cli` defaults — no
/// `-mc 0`, no `-sns`, no prompt — so it is not something Ghostie's decoding
/// flags cause or can fix, and it has to be repaired downstream.
///
/// `restore` asks the already-configured summarization provider to put the
/// punctuation back, and then **verifies that it only did that**: the
/// normalized word sequence has to come back identical or that line keeps its
/// original text. A transcript missing commas is a nuisance; one whose words
/// were quietly rewritten is a record you cannot cite, and nothing downstream
/// would ever notice. Every failure path — provider absent, unparseable
/// reply, wrong element count, changed words — keeps what whisper produced.
enum TranscriptRefiner {

    // MARK: - 1. Coalescing (pure)

    /// A turn ends when the speaker changes, when the previous line already
    /// closed a sentence, when the two lines are too far apart to be one
    /// utterance, or when the turn has grown past `maxTurnWords`.
    ///
    /// The gap is measured start-to-start because `Line` carries no end: a
    /// segment's own length is therefore inside the budget, which is why the
    /// default is generous. It exists to stop a speaker's turn absorbing
    /// something they said two minutes later after a long silence, not to
    /// judge sentence flow — the punctuation test does that.
    ///
    /// `maxTurnWords` only bites in the unpunctuated register, where nothing
    /// ever ends a sentence and a speaker's whole stretch would otherwise
    /// become one wall of text. 40 was picked against the 2026-08-28 call: it
    /// turns 570 fragments into 376 turns averaging 22.8 words, which is the
    /// same shape as the reference recording of that conversation (374 turns,
    /// 22.8 words). Higher caps drift toward paragraphs nobody reads.
    static func coalesce(_ lines: [Pipeline.Line],
                         maxJoinGapMs: Int = 15_000,
                         maxTurnWords: Int = 40) -> [Pipeline.Line] {
        var out: [Pipeline.Line] = []
        var wordsInTurn = 0
        var previousStart = 0
        for line in lines {
            let words = wordCount(line.text)
            if let current = out.last,
               current.speaker == line.speaker,
               line.startMs - previousStart <= maxJoinGapMs,
               !endsSentence(current.text),
               wordsInTurn + words <= maxTurnWords {
                out[out.count - 1] = Pipeline.Line(
                    startMs: current.startMs,
                    speaker: current.speaker,
                    text: join(current.text, line.text))
                wordsInTurn += words
            } else {
                out.append(line)
                wordsInTurn = words
            }
            previousStart = line.startMs
        }
        return out
    }

    /// Whether `text` closes a sentence. Trailing quotes and brackets are
    /// stepped over so `he said "stop."` counts.
    static func endsSentence(_ text: String) -> Bool {
        let closers: Set<Character> = ["\"", "'", "”", "’", ")", "]", "»"]
        var s = Substring(text).trimmingCharacters(in: .whitespacesAndNewlines)[...]
        while let last = s.last, closers.contains(last) { s = s.dropLast() }
        guard let last = s.last else { return false }
        return ".?!…".contains(last)
    }

    private static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        // whisper leads most segments with a space and sometimes splits
        // mid-word across a boundary; a single space is the only safe join.
        return left + " " + right
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
    }

    // MARK: - 2. Punctuation restoration

    struct Stats {
        var attempted = false
        /// Punctuation marks per 100 words, before and after. This — not the
        /// share of turns ending in a full stop — is what the pass changes: a
        /// turn cut at `maxTurnWords` ends mid-sentence, and correctly comes
        /// back still unterminated, so the terminal share barely moves even
        /// when every sentence inside the turn got its punctuation back.
        var densityBefore = 0
        var densityAfter = 0
        var restored = 0
        var rejected = 0
        var total = 0
        var summary: String {
            guard attempted else { return "punctuation: not needed" }
            var s = "punctuation: \(restored)/\(total) turns repunctuated "
                + "(\(densityBefore) → \(densityAfter) marks per 100 words)"
            if rejected > 0 { s += ", \(rejected) rejected for changed wording" }
            return s
        }
    }

    /// Punctuation marks per 100 words, rounded. The signal `needsRestoration`
    /// reads is `terminalFraction`; this is the one worth reporting after.
    static func punctuationDensity(_ lines: [Pipeline.Line]) -> Int {
        var marks = 0, words = 0
        for line in lines {
            marks += line.text.filter { ".,?!;:".contains($0) }.count
            words += wordCount(line.text)
        }
        guard words > 0 else { return 0 }
        return Int((Double(marks) / Double(words) * 100).rounded())
    }

    /// Turns per provider request. Every round-trip costs provider startup as
    /// well as generation — measured 2026-08-28, ~55 s each against
    /// `claude -p`, so 376 turns at 40 per batch spent 9 minutes, most of it
    /// paid ten times over. 80 halves that while keeping the reply well inside
    /// any model's response budget, and a batch whose reply can't be aligned
    /// only costs those turns their punctuation, never their words.
    static let batchTurns = 80
    /// Hard ceiling on requests for one call, so a pathological transcript
    /// can't run up an unbounded provider bill.
    static let maxBatches = 40

    /// True when the transcript looks like it came out of the unpunctuated
    /// register. A short transcript is not enough to judge from, and one that
    /// is already punctuated must not pay for a round-trip.
    static func needsRestoration(_ lines: [Pipeline.Line],
                                 minTurns: Int = 20,
                                 maxTerminalFraction: Double = 0.6) -> Bool {
        guard lines.count >= minTurns else { return false }
        return terminalFraction(lines) < maxTerminalFraction
    }

    static func terminalFraction(_ lines: [Pipeline.Line]) -> Double {
        guard !lines.isEmpty else { return 1 }
        return Double(lines.filter { endsSentence($0.text) }.count) / Double(lines.count)
    }

    /// Repunctuate `lines` through `provider`, keeping the original text for
    /// every line the reply cannot be trusted for.
    static func restore(_ lines: [Pipeline.Line],
                        provider: SummarizationProvider,
                        batchSize: Int = batchTurns) -> (lines: [Pipeline.Line], stats: Stats) {
        var stats = Stats()
        stats.total = lines.count
        stats.densityBefore = punctuationDensity(lines)
        guard provider.isConfigured, !lines.isEmpty else { return (lines, stats) }
        stats.attempted = true

        // The reply is about as long as the request, and the system prompt
        // rides along, so a third of the provider's stated budget is what one
        // batch may spend. Claude's 600 k never binds and `batchSize` decides;
        // Ollama's 24 k does, so a local install sends smaller batches instead
        // of overflowing its context and losing the whole thing.
        let charBudget = max(2_000, provider.maxTranscriptChars / 3)
        var out = lines
        var index = 0
        var batch = 0
        while index < lines.count, batch < maxBatches {
            let slice = Array(lines[index..<min(index + max(1, batchSize), lines.count)])
                .prefixWithinBudget(charBudget)
            let texts = slice.map(\.text)
            guard let payload = try? JSONSerialization.data(
                    withJSONObject: texts, options: []),
                  let user = String(data: payload, encoding: .utf8) else {
                index += slice.count; batch += 1; continue
            }
            guard let reply = try? provider.complete(system: system, user: user) else {
                // The provider is unreachable; every remaining batch would
                // fail the same way, so stop rather than time out 40 times.
                Log.info("Punctuation restoration skipped: the summarization model could not be reached.")
                break
            }
            if let restored = parse(reply, expecting: slice.count) {
                for (offset, candidate) in restored.enumerated() {
                    let original = slice[offset]
                    guard preservesWording(original.text, candidate) else {
                        stats.rejected += 1; continue
                    }
                    guard candidate != original.text else { continue }
                    out[index + offset] = Pipeline.Line(startMs: original.startMs,
                                                        speaker: original.speaker,
                                                        text: candidate)
                    stats.restored += 1
                }
            } else {
                stats.rejected += slice.count
            }
            index += slice.count
            batch += 1
        }
        stats.densityAfter = punctuationDensity(out)
        return (out, stats)
    }

    /// The reply, as exactly `expecting` strings, or nil. A model that
    /// returned a different number of turns has restructured the transcript
    /// rather than punctuating it, and none of it can be aligned back.
    static func parse(_ reply: String, expecting: Int) -> [String]? {
        guard let start = reply.firstIndex(of: "["),
              let end = reply.lastIndex(of: "]"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [Any]
        else { return nil }
        let strings = raw.compactMap { $0 as? String }
        guard strings.count == raw.count, strings.count == expecting else { return nil }
        return strings
    }

    /// Whether `candidate` says exactly what `original` says, differing only
    /// in punctuation and case. This is the whole safety story for handing a
    /// transcript to a language model: anything it rewrote, invented or
    /// dropped changes the word sequence and gets thrown away.
    ///
    /// Apostrophes are erased rather than treated as separators so that
    /// restoring `dont` → `don't` — which is squarely what we asked for —
    /// still compares equal.
    static func preservesWording(_ original: String, _ candidate: String) -> Bool {
        normalizedWords(original) == normalizedWords(candidate)
    }

    static func normalizedWords(_ text: String) -> [String] {
        let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{02BC}", "`"]
        var scrubbed = ""
        scrubbed.reserveCapacity(text.count)
        for ch in text.lowercased() where !apostrophes.contains(ch) {
            scrubbed.append(ch.isLetter || ch.isNumber ? ch : " ")
        }
        return scrubbed.split(separator: " ").map(String.init)
    }

    static let system = """
    You restore punctuation and capitalization in speech transcripts.

    The input is a JSON array of transcript turns. Reply with a JSON array of \
    the same length, in the same order, where each turn reads as properly \
    punctuated, properly capitalized speech.

    Rules:
    - Never add, remove, reorder or replace a word. Every word must come back \
    exactly as given, in the same order.
    - Do not translate. Do not summarize. Do not tidy away disfluencies \
    ("um", "like", stutters, repeated words) — they are part of the record.
    - Change only: sentence-ending punctuation, commas, apostrophes, and \
    capitalization of sentence starts and proper nouns.
    - A turn that is already correct comes back unchanged.

    Reply with ONLY the JSON array. No prose, no code fence, no explanation.
    """
}


private extension Array where Element == Pipeline.Line {
    /// The longest prefix whose text fits `chars`, never empty — a single turn
    /// longer than the whole budget is still sent alone, because dropping it
    /// would silently lose that turn's punctuation with nothing to show for it.
    func prefixWithinBudget(_ chars: Int) -> [Pipeline.Line] {
        var used = 0
        var taken = 0
        for line in self {
            let cost = line.text.count + 4          // JSON quoting + comma
            if taken > 0, used + cost > chars { break }
            used += cost
            taken += 1
        }
        return Array(prefix(Swift.max(1, taken)))
    }
}
