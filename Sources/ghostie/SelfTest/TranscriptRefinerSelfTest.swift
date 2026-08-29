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

    check("coalesce: a speaker change always breaks the turn",
          TranscriptRefiner.coalesce([line(0, "Jose", "and then we"),
                                      line(2_000, "David", "yeah exactly"),
                                      line(4_000, "Jose", "carried on")]).count == 3)

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
        func complete(system: String, user: String) throws -> String {
            transform(user)
        }
    }
    struct DeadProvider: SummarizationProvider {
        var isConfigured = true
        var displayStatus = "down"
        var maxTranscriptChars = 1 << 20
        func complete(system: String, user: String) throws -> String {
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
    // every turn exactly once.
    var batchSizes: [Int] = []
    let counting = StubProvider(transform: { user in
        let items = ((try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String]) ?? []
        batchSizes.append(items.count)
        return (try? String(data: JSONSerialization.data(withJSONObject: items.map { $0 + "." }),
                            encoding: .utf8)) ?? "[]"
    })
    let long = (0..<90).map { line($0 * 1_000, "Jose", "turn number \($0)") }
    let batched = TranscriptRefiner.restore(long, provider: counting, batchSize: 40)
    check("restore: 90 turns batch as 40/40/10 and every turn is covered once",
          batchSizes == [40, 40, 10] && batched.stats.restored == 90
          && batched.lines.count == 90
          && batched.lines.enumerated().allSatisfy { $1.text == "turn number \($0)." },
          "batches \(batchSizes), restored \(batched.stats.restored)")

    // A provider with a small context gets small batches, not an overflow.
    struct SmallContextProvider: SummarizationProvider {
        let record: (Int) -> Void
        var isConfigured = true
        var displayStatus = "small"
        var maxTranscriptChars = 9_000          // → 3000-char batches
        func complete(system: String, user: String) throws -> String {
            record(user.count)
            let items = ((try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String]) ?? []
            return (try? String(data: JSONSerialization.data(withJSONObject: items),
                                encoding: .utf8)) ?? "[]"
        }
    }
    var requestSizes: [Int] = []
    let wordy = (0..<60).map { line($0 * 1_000, "Jose", String(repeating: "word ", count: 30)) }
    let clamped = TranscriptRefiner.restore(
        wordy, provider: SmallContextProvider(record: { requestSizes.append($0) }))
    check("restore: a small-context provider gets batches inside its budget",
          requestSizes.count > 1 && requestSizes.allSatisfy { $0 <= 3_200 }
          && clamped.lines.count == 60,
          "sizes \(requestSizes)")
    check("restore: the char budget never starves a batch below one turn",
          TranscriptRefiner.restore(
            [line(0, "Jose", String(repeating: "x", count: 50_000))],
            provider: SmallContextProvider(record: { _ in })).lines.count == 1)

    // The shipped batch size is what production actually sends.
    var defaultBatches: [Int] = []
    let sizing = StubProvider(transform: { user in
        let items = ((try? JSONSerialization.jsonObject(with: Data(user.utf8))) as? [String]) ?? []
        defaultBatches.append(items.count)
        return (try? String(data: JSONSerialization.data(withJSONObject: items),
                            encoding: .utf8)) ?? "[]"
    })
    _ = TranscriptRefiner.restore((0..<200).map { line($0 * 1_000, "Jose", "turn \($0)") },
                                  provider: sizing)
    check("restore: the default batch size sends whole turns and covers everything",
          defaultBatches.reduce(0, +) == 200
          && defaultBatches.allSatisfy { $0 <= TranscriptRefiner.batchTurns },
          "got \(defaultBatches)")

    print("transcript-refiner self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
