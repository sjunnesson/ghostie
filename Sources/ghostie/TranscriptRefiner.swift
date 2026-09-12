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

    /// A turn, plus where each of its source lines started. `split` needs the
    /// second half: once punctuation comes back, a block is re-cut at sentence
    /// boundaries and every piece has to carry the timestamp of the line its
    /// first word actually came from, not the block's.
    struct Block {
        var line: Pipeline.Line
        /// Word offset → source line start, in order, first entry at offset 0.
        var sources: [(wordOffset: Int, startMs: Int)]
        /// Start of the last source line folded into this block.
        var lastLineStartMs: Int
        /// Words in the block, by the same whitespace count `split` uses.
        var words: Int
        var speaker: String { line.speaker }

        /// The timestamp for a piece of this block beginning at `word`.
        func startMs(atWord word: Int) -> Int {
            var ms = line.startMs
            for s in sources where s.wordOffset <= word { ms = s.startMs }
            return ms
        }
    }

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
                         maxTurnWords: Int = 40,
                         maxInterjectionWords: Int = maxInterjectionWords,
                         maxInterjectionGapMs: Int = 10_000) -> [Pipeline.Line] {
        blocks(lines, maxJoinGapMs: maxJoinGapMs, maxTurnWords: maxTurnWords,
               maxInterjectionWords: maxInterjectionWords,
               maxInterjectionGapMs: maxInterjectionGapMs).map(\.line)
    }

    /// Words a line may have and still count as a backchannel rather than a
    /// turn. "Yeah." / "Mm-hmm." / "Okay okay." are listening noises: they do
    /// not end the sentence they land in the middle of, and treating them as
    /// speaker changes is what cut 106 of the 511 unfinished turns on the
    /// 2026-09-08 call. 3 is deliberately below the length of the shortest
    /// real contribution on that call ("How old is she now?").
    static let maxInterjectionWords = 3

    /// Turns per provider request, and the block size those turns are built
    /// at. See `restore` for the first; the second is larger than any turn
    /// anyone wants to read on purpose — sentence boundaries are invisible
    /// until punctuation comes back, so cutting at 40 words first would put
    /// arbitrary breaks mid-clause that nothing downstream could distinguish
    /// from real ones. `split` cuts the readable turns afterwards, at the
    /// sentences the model just restored.
    static let blockWords = 120

    /// `coalesce`, keeping each turn's provenance. See `Block`.
    ///
    /// The one rule here that reorders anything: a turn may absorb a line that
    /// arrives *after* a short interjection from the other speaker, as long as
    /// the turn was still mid-sentence. The interjection keeps its own place
    /// and timestamp, so the record stays chronological to within the few
    /// seconds of the backchannel — and the sentence it interrupted stays a
    /// sentence, which is the whole point of the pass.
    static func blocks(_ lines: [Pipeline.Line],
                       maxJoinGapMs: Int = 15_000,
                       maxTurnWords: Int = 40,
                       maxInterjectionWords: Int = maxInterjectionWords,
                       maxInterjectionGapMs: Int = 10_000) -> [Block] {
        var out: [Block] = []

        /// Folds `line` into the block at `i`, if that block will have it.
        func absorb(_ line: Pipeline.Line, into i: Int, words: Int,
                    within budget: Int) -> Bool {
            guard out[i].line.speaker == line.speaker,
                  !endsSentence(out[i].line.text),
                  line.startMs - out[i].lastLineStartMs <= budget,
                  out[i].words + words <= maxTurnWords else { return false }
            out[i].sources.append((wordOffset: out[i].words, startMs: line.startMs))
            out[i].line = Pipeline.Line(startMs: out[i].line.startMs,
                                        speaker: out[i].line.speaker,
                                        text: join(out[i].line.text, line.text))
            out[i].words += words
            out[i].lastLineStartMs = line.startMs
            return true
        }

        for line in lines {
            let words = wordCount(line.text)
            // The line before this one, same speaker: the ordinary join.
            if let i = out.indices.last,
               absorb(line, into: i, words: words, within: maxJoinGapMs) { continue }
            // The line before *that*, with only a backchannel in between.
            if out.count >= 2, maxInterjectionWords > 0,
               out[out.count - 1].speaker != line.speaker,
               out[out.count - 1].words <= maxInterjectionWords,
               absorb(line, into: out.count - 2, words: words,
                      within: maxInterjectionGapMs) { continue }
            out.append(Block(line: line,
                             sources: [(wordOffset: 0, startMs: line.startMs)],
                             lastLineStartMs: line.startMs,
                             words: words))
        }
        return out
    }

    /// Cuts punctuated blocks back into readable turns at the sentence
    /// boundaries `restore` just put back, carrying each piece's real
    /// timestamp over from the block it came from.
    ///
    /// `restored` must be `blocks`' own lines, in order and in the same
    /// number — that is `restore`'s contract, and a mismatch means something
    /// restructured the transcript, in which case the blocks are returned
    /// untouched rather than re-cut against the wrong provenance.
    ///
    /// A block the model never punctuated (rejected, or unreachable) has no
    /// sentence boundaries to cut at, so it falls out of here whole — exactly
    /// the shape `coalesce` at `maxTurnWords` produced before this pass
    /// existed.
    static func split(_ restored: [Pipeline.Line], blocks: [Block],
                      maxTurnWords: Int = 40) -> [Pipeline.Line] {
        guard restored.count == blocks.count else { return restored }
        var out: [Pipeline.Line] = []
        for (line, block) in zip(restored, blocks) {
            var word = 0
            for piece in sentencePieces(line.text, maxWords: maxTurnWords) {
                out.append(Pipeline.Line(startMs: block.startMs(atWord: word),
                                         speaker: line.speaker, text: piece))
                word += wordCount(piece)
            }
        }
        // Back into time order. `coalesce` crossed a backchannel to keep a
        // sentence whole, which left that block's later sentences sitting
        // before the interjection they came after; now that each sentence
        // carries its own timestamp, the interjection can go back where it
        // happened — between two whole sentences instead of inside one.
        // Stable, so pieces sharing a start keep the order they were said in.
        return out.enumerated()
            .sorted { ($0.element.startMs, $0.offset) < ($1.element.startMs, $1.offset) }
            .map(\.element)
    }

    /// `text` cut into readable turns: one sentence each.
    ///
    /// A turn per sentence is the shape a reference recording of the
    /// 2026-09-08 call has (1286 turns, 14 words each) and the shape that
    /// makes a timestamp useful — every line points at the moment its own
    /// words were said. Two exceptions, in this order:
    ///
    /// - a piece under `minPieceWords` is folded back into the one before it,
    ///   which is also what absorbs the abbreviations ("Mr.", "e.g.") that
    ///   look like sentence ends, as long as that keeps it inside the budget;
    /// - a piece still over `maxWords` has no sentence boundary to cut at —
    ///   an unpunctuated block, or one the model declined to punctuate — and
    ///   is cut at the budget instead, which is exactly what `coalesce` did
    ///   before this pass existed.
    static func sentencePieces(_ text: String, maxWords: Int,
                               minPieceWords: Int = 3) -> [String] {
        var pieces: [String] = []
        for sentence in splitSentences(text) {
            if let last = pieces.last, wordCount(sentence) < minPieceWords,
               wordCount(last) + wordCount(sentence) <= maxWords {
                pieces[pieces.count - 1] = join(last, sentence)
            } else {
                pieces.append(sentence)
            }
        }
        return pieces.flatMap { budgeted($0, maxWords: maxWords) }
    }

    /// `text` in chunks of at most `maxWords` whitespace-separated words.
    private static func budgeted(_ text: String, maxWords: Int) -> [String] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard maxWords > 0, words.count > maxWords else { return [text] }
        return stride(from: 0, to: words.count, by: maxWords).map {
            words[$0..<min($0 + maxWords, words.count)].joined(separator: " ")
        }
    }

    /// Tokens whose trailing period is part of the word. Speech transcripts
    /// are thin on abbreviations, but "Mr. Smith" splitting into two turns is
    /// the kind of small wrongness a reader notices immediately. Initials
    /// ("J. Smith") are handled by the single-letter rule instead of listing
    /// the alphabet.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "st", "jr", "sr", "vs", "no", "fig",
        "inc", "ltd", "co", "etc", "e.g", "i.e", "approx", "dept", "est"
    ]

    /// Sentence-terminator scan: a break is a `.?!…` run, any closing quotes
    /// or brackets after it, and then whitespace. Nothing else counts, so
    /// decimals and mid-word periods are safe, and a period closing a known
    /// abbreviation or an initial does not break either.
    static func splitSentences(_ text: String) -> [String] {
        let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "\u{00BB}"]
        var out: [String] = []
        var current = ""
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            current.append(chars[i])
            if ".?!\u{2026}".contains(chars[i]) {
                var j = i + 1
                while j < chars.count, ".?!\u{2026}".contains(chars[j]) || closers.contains(chars[j]) {
                    current.append(chars[j]); j += 1
                }
                if (j >= chars.count || chars[j].isWhitespace),
                   !endsAbbreviation(current) {
                    let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !piece.isEmpty { out.append(piece) }
                    current = ""
                }
                i = j
                continue
            }
            i += 1
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { out.append(tail) }
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

    /// Whether the text so far ends in an abbreviation or an initial rather
    /// than a finished sentence.
    private static func endsAbbreviation(_ text: String) -> Bool {
        guard let token = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .last?.lowercased() else { return false }
        let word = token.trimmingCharacters(in: CharacterSet(charactersIn: ".?!\u{2026}\"')]"))
        return word.count == 1 && word.first?.isLetter == true
            || abbreviations.contains(word)
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
        /// Batches whose request failed outright (timeout, non-zero exit, a
        /// rate limiter). Their turns keep whisper's text, and — unlike a
        /// rejected reply — nothing about the transcript says so, which is
        /// why this is counted and reported.
        var failedBatches = 0
        var totalBatches = 0
        /// Punctuation marks per 100 words, before and after. This — not the
        /// share of turns ending in a full stop — is what the pass changes: a
        /// turn cut at `maxTurnWords` ends mid-sentence, and correctly comes
        /// back still unterminated, so the terminal share barely moves even
        /// when every sentence inside the turn got its punctuation back.
        var densityBefore = 0
        var densityAfter = 0
        var restored = 0
        var rejected = 0
        /// Blocks that already read as punctuated and were never sent.
        var skipped = 0
        var total = 0
        var summary: String {
            guard attempted else { return "punctuation: not needed" }
            var s = "punctuation: \(restored)/\(total) turns repunctuated "
                + "(\(densityBefore) → \(densityAfter) marks per 100 words)"
            if skipped > 0 { s += ", \(skipped) already punctuated" }
            if rejected > 0 { s += ", \(rejected) rejected for changed wording" }
            if failedBatches > 0 {
                s += " — \(failedBatches) of \(totalBatches) batches failed even on retry "
                    + "and kept whisper's text"
            }
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
    /// …but never more than this many characters of transcript per request,
    /// whatever the provider's context would allow. `batchTurns` alone sized
    /// a request when a turn was capped at 40 words; blocks are three times
    /// that, and 80 of them would be a ~10 000-word request answered by a
    /// ~10 000-word reply — one truncation or one rewritten word and 80 blocks
    /// lose their punctuation together. 12 000 chars (~2 000 words) is the
    /// size the batches that worked on the 2026-08-28 and 2026-09-08 calls
    /// actually were. A provider with a smaller context still wins: the two
    /// budgets are taken together.
    static let maxBatchChars = 12_000
    /// Hard ceiling on requests for one call, so a pathological transcript
    /// can't run up an unbounded provider bill.
    static let maxBatches = 40

    /// Whether one block still needs punctuating.
    ///
    /// whisper's unpunctuated register comes and goes in multi-minute
    /// stretches, so a call is a mix: on the 2026-09-08 call 379 of 858
    /// blocks came back from the model unchanged, each having cost a full
    /// round-trip to be told nothing was wrong. A block that ends a sentence
    /// *and* carries ordinary punctuation density is left alone.
    ///
    /// The floor is 10 marks per 100 words. Measured on that call: whisper's
    /// unpunctuated register runs at 2–6 and its punctuated output, like the
    /// restored text, at 20–22, so the two populations are far apart and the
    /// threshold sits between them rather than inside either. Erring toward
    /// sending is deliberate — a wasted request costs seconds, a block left
    /// in run-on costs the reader.
    static let punctuatedDensityFloor = 10

    static func needsPunctuation(_ text: String) -> Bool {
        guard endsSentence(text) else { return true }
        let words = wordCount(text)
        guard words >= 12 else { return false }   // too short to judge density
        let marks = text.filter { ".,?!;:".contains($0) }.count
        return marks * 100 / words < punctuatedDensityFloor
    }

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
        let charBudget = min(maxBatchChars, max(2_000, provider.maxTranscriptChars / 3))

        // Cut the whole transcript into batches first. They are independent —
        // one batch's punctuation never depends on another's — so the walk is
        // sequential and the requests are not.
        let pending = lines.indices.filter { needsPunctuation(lines[$0].text) }
        stats.skipped = lines.count - pending.count
        var batches: [(indices: [Int], slice: [Pipeline.Line])] = []
        var cursor = 0
        while cursor < pending.count, batches.count < maxBatches {
            let window = Array(pending[cursor..<min(cursor + max(1, batchSize),
                                                    pending.count)])
            let slice = window.map { lines[$0] }.prefixWithinBudget(charBudget)
            guard !slice.isEmpty else { break }
            batches.append((Array(window.prefix(slice.count)), slice))
            cursor += slice.count
        }

        let sink = Sink(lines: lines)
        let queue = DispatchQueue(label: "ghostie.punctuation", attributes: .concurrent)
        let inFlight = DispatchSemaphore(value: maxConcurrentBatches)
        let group = DispatchGroup()
        for (n, batch) in batches.enumerated() {
            let texts = batch.slice.map(\.text)
            guard let payload = try? JSONSerialization.data(withJSONObject: texts,
                                                            options: []),
                  let user = String(data: payload, encoding: .utf8) else { continue }
            inFlight.wait()
            // Several batches failing is evidence the provider is unreachable
            // or refusing the load; the ones already running finish, no new
            // ones start.
            guard !sink.providerIsDown else { inFlight.signal(); break }
            queue.async(group: group) {
                defer { inFlight.signal() }
                let label = "Restoring punctuation (batch \(n + 1)/\(batches.count))"
                /// One round-trip that produced a reply of the right shape.
                /// A request that throws and a reply that cannot be aligned
                /// are the same thing from here: no usable answer — but not
                /// for the same reason, and `why` keeps them apart. Without
                /// it the log says a batch failed and nothing about whether
                /// the provider timed out, refused the load, or answered with
                /// something that couldn't be aligned, which is the
                /// difference between diagnosing the next one and guessing.
                var why = "no reply"
                func attempt(_ purpose: String) -> [String]? {
                    do {
                        let reply = try provider.complete(system: system, user: user,
                                                          purpose: purpose)
                        guard let parsed = parse(reply, expecting: batch.slice.count) else {
                            why = "reply could not be aligned to \(batch.slice.count) turns"
                            return nil
                        }
                        return parsed
                    } catch {
                        why = error.localizedDescription
                        return nil
                    }
                }
                var restored = attempt(label)
                if restored == nil {
                    // Say so now, not only in the end-of-pass tally: a batch
                    // that fails and then succeeds on retry leaves no trace
                    // there, and a run of these is how a slow provider shows
                    // itself while the pass is still going.
                    Log.warn("Punctuation batch \(n + 1)/\(batches.count) failed "
                        + "(\(why)) — retrying once.")
                    Thread.sleep(forTimeInterval: batchRetryDelay)
                    restored = attempt(label + ", retry")
                }
                guard let restored else {
                    sink.batchFailed(max: maxBatchFailures, why: why)
                    return
                }
                for (offset, candidate) in restored.enumerated() {
                    let original = batch.slice[offset]
                    guard preservesWording(original.text, candidate) else {
                        sink.reject(1); continue
                    }
                    guard candidate != original.text else { continue }
                    sink.accept(at: batch.indices[offset],
                                Pipeline.Line(startMs: original.startMs,
                                              speaker: original.speaker,
                                              text: candidate))
                }
            }
        }
        group.wait()
        if sink.failures > 0 {
            let detail = sink.reasons.map { "\"\($0)\"" }.joined(separator: ", ")
            Log.warn("Punctuation: \(sink.failures) of \(batches.count) batches failed twice "
                + "(\(detail)) — those turns keep whisper's text."
                + (sink.providerIsDown ? " Remaining batches were not attempted." : ""))
        }
        let out = sink.result
        stats.restored = sink.restored
        stats.rejected = sink.rejected
        stats.failedBatches = sink.failures
        stats.totalBatches = batches.count
        stats.densityAfter = punctuationDensity(out)
        return (out, stats)
    }

    /// Batches in flight at once. Each one is a whole provider round-trip —
    /// on the 2026-09-08 call, 14 of them at ~90 s apiece spent 21 minutes of
    /// a 62-minute post-processing run waiting in series.
    ///
    /// Three, not four: at four, that same call came back with roughly a
    /// third of its blocks unpunctuated because several batches failed at
    /// once, and the summary request that followed timed out too — the
    /// signature of a burst a rate limiter is refusing, not of a dead
    /// provider. Speed here is worth having only while the work survives.
    static let maxConcurrentBatches = 3

    /// One retry per batch, after a short pause. A batch that fails alone is
    /// almost always transient (a timeout, a throttle); a provider that is
    /// genuinely gone fails the retry too and `maxBatchFailures` stops the run.
    static let batchRetryDelay: TimeInterval = 3

    /// Distinct batches that may fail before the rest are abandoned. Under
    /// concurrency a single failure is not evidence the provider is gone —
    /// which is what the first version of this assumed, quietly dropping
    /// every remaining batch's punctuation on one timeout.
    static let maxBatchFailures = 3

    /// The mutable half of `restore`, made explicit because the batches write
    /// to it from several threads at once. Every write is to a distinct index
    /// of `lines`, but Swift arrays are not safe to mutate concurrently even
    /// then, so all of it goes through one lock.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [Pipeline.Line]
        private var down = false
        private(set) var restored = 0
        private(set) var rejected = 0
        private(set) var failures = 0
        private(set) var reasons: [String] = []

        init(lines: [Pipeline.Line]) { self.lines = lines }

        var result: [Pipeline.Line] { lock.lock(); defer { lock.unlock() }; return lines }
        var providerIsDown: Bool { lock.lock(); defer { lock.unlock() }; return down }
        /// Records a batch that failed twice; `max` of them stops the run.
        func batchFailed(max: Int, why: String) {
            lock.lock()
            failures += 1
            // Distinct reasons only: five batches timing out is one fact.
            if !reasons.contains(why) { reasons.append(why) }
            if failures >= max { down = true }
            lock.unlock()
        }
        func reject(_ n: Int) { lock.lock(); rejected += n; lock.unlock() }
        func accept(at i: Int, _ line: Pipeline.Line) {
            lock.lock(); lines[i] = line; restored += 1; lock.unlock()
        }
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
