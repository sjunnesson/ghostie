import Foundation

/// Regression check for the readability pass. The coalescer is pure; the
/// restoration path is exercised through a stub provider, so this suite needs
/// no model, no network and no audio.
func runTranscriptRefinerSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)  \(detail())") }
    }
    func line(_ ms: Int, _ speaker: String, _ text: String) -> Pipeline.Line {
        Pipeline.Line(startMs: ms, speaker: speaker, text: text)
    }

    // MARK: endsSentence

    check("endsSentence: a period ends one", TranscriptRefiner.endsSentence("that's it."))
    check("endsSentence: ? and ! end one",
          TranscriptRefiner.endsSentence("really?") && TranscriptRefiner.endsSentence("stop!"))
    check("endsSentence: an ellipsis ends one", TranscriptRefiner.endsSentence("well…"))
    check("endsSentence: a closing quote is stepped over",
          TranscriptRefiner.endsSentence("he said \"stop.\""))
    check("endsSentence: a bare clause does not",
          !TranscriptRefiner.endsSentence("and then we asked them to select one of"))
    check("endsSentence: a trailing comma does not",
          !TranscriptRefiner.endsSentence("so yeah, like,"))
    check("endsSentence: empty text does not", !TranscriptRefiner.endsSentence("   "))

    // MARK: coalesce — the defect this exists for

    // The real 2026-08-28 shape: one sentence split across three segments.
    let split = [line(0, "Jose", "means in the first round you have at least 60 ideas and then we asked them to select one of"),
                 line(9_000, "Jose", "ideas and then in order to like specify what that idea was"),
                 line(18_000, "Jose", "we also make this kind of like canvas.")]
    let joined = TranscriptRefiner.coalesce(split)
    check("coalesce: an unpunctuated run becomes one turn, keeping the first timestamp",
          joined.count == 1 && joined[0].startMs == 0
          && joined[0].text.hasPrefix("means in the first round")
          && joined[0].text.hasSuffix("kind of like canvas."),
          "got \(joined.map(\.text))")

    // A backchannel is not a turn: the sentence it lands inside survives it,
    // and the interjection keeps its own place and timestamp.
    let crossed = TranscriptRefiner.coalesce([line(0, "Jose", "and then we"),
                                              line(2_000, "David", "yeah exactly"),
                                              line(4_000, "Jose", "carried on")])
    check("coalesce: a short backchannel does not break the sentence it lands in",
          crossed.count == 2
          && crossed[0].speaker == "Jose" && crossed[0].startMs == 0
          && crossed[0].text == "and then we carried on"
          && crossed[1].speaker == "David" && crossed[1].startMs == 2_000,
          "got \(crossed.map { "\($0.speaker):\($0.text)" })")

    check("coalesce: a real contribution from the other speaker does break it",
          TranscriptRefiner.coalesce(
            [line(0, "Jose", "and then we"),
             line(2_000, "David", "hold on how old is she now"),
             line(4_000, "Jose", "carried on")]).count == 3)

    check("coalesce: a finished sentence is never crossed",
          TranscriptRefiner.coalesce([line(0, "Jose", "That is that."),
                                      line(2_000, "David", "yeah"),
                                      line(4_000, "Jose", "New thought")]).count == 3)

    check("coalesce: two backchannels in a row end the turn",
          TranscriptRefiner.coalesce([line(0, "Jose", "and then we"),
                                      line(2_000, "David", "yeah"),
                                      line(3_000, "Ana", "mm hmm"),
                                      line(4_000, "Jose", "carried on")]).count == 4)

    check("coalesce: a backchannel is not crossed after a long silence",
          TranscriptRefiner.coalesce([line(0, "Jose", "and then we"),
                                      line(2_000, "David", "yeah"),
                                      line(60_000, "Jose", "carried on")]).count == 3)

    check("coalesce: crossing is off when maxInterjectionWords is 0",
          TranscriptRefiner.coalesce([line(0, "Jose", "and then we"),
                                      line(2_000, "David", "yeah exactly"),
                                      line(4_000, "Jose", "carried on")],
                                     maxInterjectionWords: 0).count == 3)

    check("coalesce: a finished sentence is not glued to the next one",
          TranscriptRefiner.coalesce([line(0, "Jose", "That is the whole thing."),
                                      line(2_000, "Jose", "And it worked well.")]).count == 2)

    check("coalesce: a long silence breaks the turn even mid-sentence",
          TranscriptRefiner.coalesce([line(0, "Jose", "and then we"),
                                      line(60_000, "Jose", "carried on")],
                                     maxJoinGapMs: 15_000).count == 2)

    // The degraded register punctuates nothing, so only the word cap can stop
    // the whole track collapsing into one wall of text.
    let endless = (0..<40).map { line($0 * 2_000, "Jose", "and then we kept going") }
    let capped = TranscriptRefiner.coalesce(endless, maxTurnWords: 20)
    check("coalesce: the word cap bounds a turn when nothing ever ends a sentence",
          capped.count > 1 && capped.allSatisfy { $0.text.split(separator: " ").count <= 20 },
          "got \(capped.count) turns, max \(capped.map { $0.text.split(separator: " ").count }.max() ?? 0) words")

    check("coalesce: an empty transcript stays empty",
          TranscriptRefiner.coalesce([]).isEmpty)
    check("coalesce: timestamps and speakers survive untouched",
          TranscriptRefiner.coalesce([line(5_000, "David", "One. "), line(7_000, "David", "Two.")])
            .map { ($0.startMs, $0.speaker) }.elementsEqual([(5_000, "David"), (7_000, "David")], by: ==))

    // MARK: preservesWording — the safety story

    check("preservesWording: punctuation and case only → accepted",
          TranscriptRefiner.preservesWording("so yeah i don't know um i've been in",
                                             "So yeah, I don't know. Um, I've been in"))
    check("preservesWording: restoring a missing apostrophe → accepted",
          TranscriptRefiner.preservesWording("i dont think so", "I don't think so."))
    check("preservesWording: a dropped word → rejected",
          !TranscriptRefiner.preservesWording("so yeah i don't know um i've been in",
                                              "So yeah, I don't know. I've been in."))
    check("preservesWording: an added word → rejected",
          !TranscriptRefiner.preservesWording("we shipped it", "We actually shipped it."))
    check("preservesWording: a substituted word → rejected",
          !TranscriptRefiner.preservesWording("we shipped it", "We released it."))
    check("preservesWording: reordering → rejected",
          !TranscriptRefiner.preservesWording("it shipped late", "Late, it shipped."))
    check("preservesWording: a translated turn → rejected",
          !TranscriptRefiner.preservesWording("jag vet inte", "I don't know."))
    check("preservesWording: numbers must match too",
          !TranscriptRefiner.preservesWording("about 60 ideas", "About 16 ideas."))

    // MARK: parse

    check("parse: a clean JSON array of the right length",
          TranscriptRefiner.parse("[\"One.\", \"Two.\"]", expecting: 2) == ["One.", "Two."])
    check("parse: a fenced reply with prose still parses",
          TranscriptRefiner.parse("Sure!\n```json\n[\"One.\"]\n```", expecting: 1) == ["One."])
    check("parse: a different element count is refused",
          TranscriptRefiner.parse("[\"One.\"]", expecting: 2) == nil)
    check("parse: a non-string element is refused",
          TranscriptRefiner.parse("[\"One.\", 2]", expecting: 2) == nil)
    check("parse: junk is refused", TranscriptRefiner.parse("no idea", expecting: 1) == nil)

    // MARK: needsRestoration

    let unpunctuated = (0..<30).map { line($0 * 1_000, "Jose", "and then we kept going") }
    let punctuated = (0..<30).map { line($0 * 1_000, "Jose", "And then we kept going.") }
    check("needsRestoration: an unpunctuated transcript needs it",
          TranscriptRefiner.needsRestoration(unpunctuated))
    check("needsRestoration: an already-punctuated one does not",
          !TranscriptRefiner.needsRestoration(punctuated))
    check("needsRestoration: too few turns to judge → no round-trip",
          !TranscriptRefiner.needsRestoration(Array(unpunctuated.prefix(5))))

    // MARK: restore — end to end against a stub provider

    struct StubProvider: SummarizationProvider {
        let transform: (String) -> String
        var isConfigured = true
        var displayStatus = "stub"
        var maxTranscriptChars = 1 << 20
        func complete(system: String, user: String, purpose: String) throws -> String {
            transform(user)
        }
    }
    struct DeadProvider: SummarizationProvider {
        var isConfigured = true
        var displayStatus = "down"
        var maxTranscriptChars = 1 << 20
        func complete(system: String, user: String, purpose: String) throws -> String {
            throw NSError(domain: "ghostie", code: 1)
        }
    }

    let rough = [line(0, "Jose", "so yeah i don't know"),
                 line(2_000, "David", "i've been in this thing")]

    // Honest provider: punctuates, keeps every word.
    let honest = StubProvider(transform: { _ in
        "[\"So yeah, I don't know.\", \"I've been in this thing.\"]"
    })
    let good = TranscriptRefiner.restore(rough, provider: honest)
    check("restore: punctuated text is taken, timestamps and speakers untouched",
          good.lines.map(\.text) == ["So yeah, I don't know.", "I've been in this thing."]
          && good.lines.map(\.startMs) == [0, 2_000]
          && good.lines.map(\.speaker) == ["Jose", "David"]
          && good.stats.restored == 2 && good.stats.rejected == 0,
          good.stats.summary)
    check("restore: reports the punctuation lift as marks per 100 words",
          good.stats.densityBefore == 0 && good.stats.densityAfter > 20,
          good.stats.summary)

    // Rewriting provider: line 2 says something else. Line 1 is still taken.
    let meddling = StubProvider(transform: { _ in
        "[\"So yeah, I don't know.\", \"I have been working on this thing.\"]"
    })
    let mixed = TranscriptRefiner.restore(rough, provider: meddling)
    check("restore: a rewritten line keeps whisper's original, a clean one is taken",
          mixed.lines[0].text == "So yeah, I don't know."
          && mixed.lines[1].text == "i've been in this thing"
          && mixed.stats.restored == 1 && mixed.stats.rejected == 1,
          mixed.stats.summary)

    // Truncating provider: the batch can't be aligned, so none of it is used.
    let truncating = StubProvider(transform: { _ in "[\"So yeah, I don't know.\"]" })
    let dropped = TranscriptRefiner.restore(rough, provider: truncating)
    check("restore: a reply with the wrong element count changes nothing",
          dropped.lines.map(\.text) == rough.map(\.text) && dropped.stats.restored == 0)

    let babbling = StubProvider(transform: { _ in "I'd be happy to help!" })
    check("restore: an unparseable reply changes nothing",
          TranscriptRefiner.restore(rough, provider: babbling).lines.map(\.text)
            == rough.map(\.text))

    let dead = TranscriptRefiner.restore(rough, provider: DeadProvider())
    check("restore: an unreachable provider changes nothing",
          dead.lines.map(\.text) == rough.map(\.text) && dead.stats.restored == 0)

    // The request carries the turns as a JSON array, in order.
    var seen = ""
    let recording = StubProvider(transform: { user in
        seen = user
        return "[\"So yeah, I don't know.\", \"I've been in this thing.\"]"
    })
    _ = TranscriptRefiner.restore(rough, provider: recording)
    check("restore: the request is a JSON array of the turns, in order",
          (try? JSONSerialization.jsonObject(with: Data(seen.utf8))) as? [String]
            == rough.map(\.text),
          seen)

    // Batching: 90 turns must arrive as three requests of 40/40/10, covering
    // every turn exactly once. The batches run concurrently, so what they
    // report is a multiset — the order they finish in is not a contract, and
    // the recorder has to be safe to call from several threads.
    final class Sizes: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func add(_ n: Int) { lock.lock(); values.append(n); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }
    let batchSizes = Sizes()
    let counting = StubProvider(transform: { user in
        let items = ((try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String]) ?? []
        batchSizes.add(items.count)
        return (try? String(data: JSONSerialization.data(withJSONObject: items.map { $0 + "." }),
                            encoding: .utf8)) ?? "[]"
    })
    let long = (0..<90).map { line($0 * 1_000, "Jose", "turn number \($0)") }
    let batched = TranscriptRefiner.restore(long, provider: counting, batchSize: 40)
    check("restore: 90 turns batch as 40/40/10 and every turn is covered once",
          batchSizes.all.sorted() == [10, 40, 40] && batched.stats.restored == 90
          && batched.lines.count == 90
          && batched.lines.enumerated().allSatisfy { $1.text == "turn number \($0)." },
          "batches \(batchSizes.all), restored \(batched.stats.restored)")

    // A provider with a small context gets small batches, not an overflow.
    struct SmallContextProvider: SummarizationProvider {
        let record: (Int) -> Void
        var isConfigured = true
        var displayStatus = "small"
        var maxTranscriptChars = 9_000          // → 3000-char batches
        func complete(system: String, user: String, purpose: String) throws -> String {
            record(user.count)
            let items = ((try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String]) ?? []
            return (try? String(data: JSONSerialization.data(withJSONObject: items),
                                encoding: .utf8)) ?? "[]"
        }
    }
    let sizes = Sizes()
    let wordy = (0..<60).map { line($0 * 1_000, "Jose", String(repeating: "word ", count: 30)) }
    let clamped = TranscriptRefiner.restore(
        wordy, provider: SmallContextProvider(record: { sizes.add($0) }))
    let requestSizes = sizes.all
    check("restore: a small-context provider gets batches inside its budget",
          requestSizes.count > 1 && requestSizes.allSatisfy { $0 <= 3_200 }
          && clamped.lines.count == 60,
          "sizes \(requestSizes)")
    check("restore: the char budget never starves a batch below one turn",
          TranscriptRefiner.restore(
            [line(0, "Jose", String(repeating: "x", count: 50_000))],
            provider: SmallContextProvider(record: { _ in })).lines.count == 1)

    // The shipped batch size is what production actually sends.
    let defaultBatches = Sizes()
    let sizing = StubProvider(transform: { user in
        let items = ((try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String]) ?? []
        defaultBatches.add(items.count)
        return (try? String(data: JSONSerialization.data(withJSONObject: items),
                            encoding: .utf8)) ?? "[]"
    })
    _ = TranscriptRefiner.restore((0..<200).map { line($0 * 1_000, "Jose", "turn \($0)") },
                                  provider: sizing)
    check("restore: the default batch size sends whole turns and covers everything",
          defaultBatches.all.reduce(0, +) == 200
          && defaultBatches.all.allSatisfy { $0 <= TranscriptRefiner.batchTurns },
          "got \(defaultBatches.all)")

    // A batch cannot see another batch's work, so running them at once must
    // change nothing but the wall-clock: same words, same order, same count.
    let wide = (0..<200).map { line($0 * 1_000, "Jose", "turn number \($0)") }
    let concurrent = TranscriptRefiner.restore(wide, provider: StubProvider(transform: { user in
        let items = ((try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String]) ?? []
        return (try? String(data: JSONSerialization.data(withJSONObject: items.map { $0 + "." }),
                            encoding: .utf8)) ?? "[]"
    }), batchSize: 7)
    check("restore: 29 concurrent batches land in the right places",
          concurrent.lines.count == 200 && concurrent.stats.restored == 200
          && concurrent.lines.enumerated()
              .allSatisfy { $1.text == "turn number \($0)." && $1.startMs == $0 * 1_000 },
          "restored \(concurrent.stats.restored)")

    let allDead = TranscriptRefiner.restore(wide, provider: DeadProvider(), batchSize: 7)
    check("restore: one unreachable provider does not corrupt the transcript",
          allDead.lines.map(\.text) == wide.map(\.text))
    // Give-up is bounded, not exact: the batches already in flight when the
    // limit is reached still finish and still count.
    check("restore: a dead provider is given up on, not attempted 29 times",
          (TranscriptRefiner.maxBatchFailures
            ..< TranscriptRefiner.maxBatchFailures + TranscriptRefiner.maxConcurrentBatches)
            .contains(allDead.stats.failedBatches),
          allDead.stats.summary)

    // The failure that matters is the *transient* one: under concurrency a
    // single timeout is not evidence the provider is gone, and the first
    // version of this dropped every remaining batch's punctuation on one.
    final class Flaky: @unchecked Sendable {
        private let lock = NSLock()
        private var seen = 0
        /// Answers uselessly the first time only, correctly after that.
        func take() -> Bool { lock.lock(); defer { lock.unlock() }; seen += 1; return seen > 1 }
    }
    let flaky = Flaky()
    let recovered = TranscriptRefiner.restore(
        wide,
        provider: StubProvider(transform: { user in
            guard flaky.take() else { return "provider is busy" }
            let items = ((try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String]) ?? []
            return (try? String(data: JSONSerialization.data(withJSONObject: items.map { $0 + "." }),
                                encoding: .utf8)) ?? "[]"
        }),
        batchSize: 7)
    check("restore: one flaky batch is retried, and the rest are never abandoned",
          recovered.stats.failedBatches == 0 && recovered.stats.restored == 200,
          recovered.stats.summary)

    // MARK: needsPunctuation — don't pay a round-trip to be told nothing's wrong

    check("needsPunctuation: whisper's run-on register needs it",
          TranscriptRefiner.needsPunctuation(
            "so yeah i think that the challenge is like kids are just growing in "
            + "different directions and priorities and it is hard to find her spot"))

    check("needsPunctuation: properly punctuated prose does not",
          !TranscriptRefiner.needsPunctuation(
            "So yeah, I think the challenge is that kids grow in different "
            + "directions, and it's hard to find her spot. They've been the "
            + "same ten girls for five years."))

    check("needsPunctuation: a full stop alone is not enough — density counts",
          TranscriptRefiner.needsPunctuation(
            "so yeah i think that the challenge is like kids are just growing "
            + "in different directions and priorities and it is hard to find her spot."))

    check("needsPunctuation: a short turn is judged on its ending only",
          !TranscriptRefiner.needsPunctuation("Yeah, exactly.")
          && TranscriptRefiner.needsPunctuation("yeah exactly"))

    do {
        // Half the blocks already read fine: only the other half is sent, and
        // the ones left alone come back untouched rather than missing.
        let mixed = (0..<40).map { i -> Pipeline.Line in
            line(i * 1_000, "Jose",
                 i % 2 == 0
                    ? "This one is already fine, properly punctuated, and it ends."
                    : "this one is not punctuated at all and just runs on and on and on")
        }
        var sent = 0
        let counting = StubProvider(transform: { user in
            let items = ((try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String]) ?? []
            sent += items.count
            return (try? String(data: JSONSerialization.data(
                        withJSONObject: items.map { $0.uppercased() }), encoding: .utf8)) ?? "[]"
        })
        let out = TranscriptRefiner.restore(mixed, provider: counting, batchSize: 80)
        check("restore: only the blocks that need punctuating are sent",
              sent == 20 && out.stats.skipped == 20, "sent \(sent), \(out.stats.summary)")
        check("restore: the skipped blocks are returned untouched, in place",
              out.lines.count == 40
              && out.lines.enumerated().allSatisfy { i, l in
                    i % 2 == 0 ? l.text == mixed[i].text : l.text == mixed[i].text.uppercased()
                 })
    }

    // MARK: blocks + split — the shape the reader actually gets

    // The 2026-09-08 shape: whisper's segments, a backchannel landing inside
    // one sentence, and no punctuation anywhere until the model puts it back.
    let raw = [line(0, "Me", "so the challenge is like kids are just growing in"),
               line(4_000, "Participant 1", "thank you"),
               line(8_000, "Me", "different directions and priorities and it is hard"),
               line(13_000, "Me", "to find her spot there they have been the same ten girls")]
    let blocks = TranscriptRefiner.blocks(raw, maxTurnWords: TranscriptRefiner.blockWords)
    check("blocks: one speaker's sentence survives a backchannel as one block",
          blocks.count == 2 && blocks[0].line.speaker == "Me"
          && blocks[0].words == 30 && blocks[0].sources.count == 3
          && blocks[1].line.speaker == "Participant 1",
          "got \(blocks.map { "\($0.line.speaker):\($0.words)w" })")

    check("blocks: a source's timestamp is the line its words came from",
          blocks[0].startMs(atWord: 0) == 0
          && blocks[0].startMs(atWord: 11) == 8_000
          && blocks[0].startMs(atWord: 29) == 13_000,
          "offsets \(blocks[0].sources.map { "\($0.wordOffset)@\($0.startMs)" })")

    let restoredBlocks = [Pipeline.Line(startMs: 0, speaker: "Me",
                                    text: "So the challenge is, like, kids are just growing in "
                                        + "different directions and priorities, and it is hard "
                                        + "to find her spot there. They have been the same ten girls."),
                      blocks[1].line]
    let pieces = TranscriptRefiner.split(restoredBlocks, blocks: blocks, maxTurnWords: 40)
    check("split: a block is cut at the sentence, not at the word budget",
          pieces.count == 3 && pieces[0].text.hasSuffix("spot there.")
          && pieces[2].text == "They have been the same ten girls."
          && pieces[2].startMs == 13_000,
          "got \(pieces.map { "[\($0.startMs)] \($0.text)" })")

    check("split: the crossed backchannel lands back between whole sentences",
          pieces.map(\.startMs) == [0, 4_000, 13_000]
          && pieces[1].speaker == "Participant 1",
          "got \(pieces.map { "[\($0.startMs)] \($0.speaker)" })")

    check("split: an unpunctuated block comes back whole",
          TranscriptRefiner.split(blocks.map(\.line), blocks: blocks).count == blocks.count)

    check("split: a misaligned reply is never re-cut against the wrong blocks",
          TranscriptRefiner.split(Array(restoredBlocks.prefix(1)), blocks: blocks).count == 1)

    // Per speaker, because the pieces are re-interleaved by time on the way
    // out: what has to survive is every word, in order, from each of them.
    check("split: every word survives the round trip, per speaker",
          ["Me", "Participant 1"].allSatisfy { who in
              TranscriptRefiner.normalizedWords(
                  pieces.filter { $0.speaker == who }.map(\.text).joined(separator: " "))
              == TranscriptRefiner.normalizedWords(
                  restoredBlocks.filter { $0.speaker == who }.map(\.text).joined(separator: " "))
          })

    check("sentencePieces: one sentence per turn, not packed to the budget",
          TranscriptRefiner.sentencePieces("One thing happened. Then another thing did.",
                                           maxWords: 40).count == 2)

    check("sentencePieces: a block with no sentence in it still gets cut at the budget",
          TranscriptRefiner.sentencePieces(
            (0..<95).map { "word\($0)" }.joined(separator: " "),
            maxWords: 40).map { $0.split(separator: " ").count } == [40, 40, 15])

    check("sentencePieces: a scrap is folded back into the sentence before it",
          TranscriptRefiner.sentencePieces("We met Mr. Smith at the office. Yes.",
                                           maxWords: 40) == ["We met Mr. Smith at the office. Yes."])

    check("splitSentences: a decimal is not a sentence end",
          TranscriptRefiner.splitSentences("it was 3.5 million. Really.")
            == ["it was 3.5 million.", "Really."])

    check("splitSentences: a closing quote rides with its sentence",
          TranscriptRefiner.splitSentences("he said \"stop.\" Then he left.")
            == ["he said \"stop.\"", "Then he left."])

    print("transcript-refiner self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
