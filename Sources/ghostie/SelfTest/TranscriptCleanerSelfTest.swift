import Foundation

// Extracted from main.swift: the selftest suites are deliberately compiled
// into the shipping binary — `ghostie selftest` must run on any installed
// copy (no dev tools needed) — but they live in SelfTest/ so main.swift
// stays the entry point, not a 1400-line test host.

/// Built-in regression check for the hallucination guard, over the patterns
/// it targets (whisper emits these as separate short segments on bad audio).
func runTranscriptCleanerSelfTest() -> Bool {
    func seg(_ texts: [String]) -> [(startMs: Int, text: String)] {
        texts.enumerated().map { (startMs: $0.offset * 1000, text: $0.element) }
    }
    var passed = 0, failed = 0
    func check(_ name: String, _ input: [String], _ predicate: ([String]) -> Bool) {
        let (out, stats) = TranscriptCleaner.clean(seg(input))
        let texts = out.map { $0.text }
        if predicate(texts) {
            passed += 1; print("  ✓ \(name)  (\(stats.summary))")
        } else {
            failed += 1
            print("  ✗ \(name)\n      in:  \(input)\n      out: \(texts)")
        }
    }

    // Silence loop → collapses to one + an annotation.
    check("silence loop collapses", Array(repeating: "Thank you.", count: 12)
          + ["What is the Q3 budget?"]) { out in
        out.contains { $0.contains("repeated audio removed") }
        && out.contains { $0.contains("Q3 budget") }
        && out.filter { $0 == "Thank you." }.count <= 1
    }
    // YouTube / Amara training-data leaks dropped; real content kept.
    check("known hallucinations dropped",
          ["Thanks for watching!", "Please subscribe to our channel",
           "Subtitles by the Amara.org community", "www.amara.org",
           "Let's approve the migration plan."]) { out in
        out == ["Let's approve the migration plan."]
    }
    // Noise-marker run collapses; trailing noise trimmed.
    check("noise markers + trailing trim",
          ["Decision: ship Friday.", "[BLANK_AUDIO]", "[BLANK_AUDIO]",
           "[BLANK_AUDIO]", "[ Silence ]", "[music]"]) { out in
        out == ["Decision: ship Friday."]
    }
    // A dominant hallucinated *content* phrase interleaved with junk
    // collapses to one occurrence; pure filler backchannel is intentionally
    // preserved, so the dominant phrase here is real-looking content.
    check("interleaved drift collapses",
          ["The meeting is being recorded.", "uh",
           "The meeting is being recorded.", "um",
           "The meeting is being recorded.", "hmm",
           "The meeting is being recorded.", "okay",
           "The meeting is being recorded.", "right",
           "The meeting is being recorded.", "Decision: launch next week."]) { out in
        out.filter { $0 == "The meeting is being recorded." }.count == 1
        && out.contains { $0.contains("Decision: launch next week.") }
        && out.count < 12
    }
    // Clean speech is untouched (no false positives).
    check("clean speech untouched",
          ["Hi everyone.", "We shipped the feature.", "Next steps are clear.",
           "Thanks, talk soon."]) { out in
        out == ["Hi everyone.", "We shipped the feature.",
                "Next steps are clear.", "Thanks, talk soon."]
    }

    // Within-segment loops: whisper also loops *inside* one segment
    // ("Yeah, yeah, ×14" as a single segment on backchannel audio), which
    // the across-segment consecutive collapse can't see.
    check("within-segment loop collapses",
          ["Great point.",
           "Yeah, yeah, yeah, yeah, yeah, yeah, yeah, yeah, yeah, yeah, "
           + "yeah, yeah, yeah, yeah,",
           "Let's continue."]) { out in
        out == ["Great point.", "Yeah.", "Let's continue."]
    }
    check("within-segment multi-word loop collapses",
          ["I'm sorry. I'm sorry. I'm sorry. I'm sorry. I'm sorry. Let's move on."]) { out in
        out == ["I'm sorry. Let's move on."]
    }
    // Genuine emphasis (≤3 repeats) must never be collapsed.
    check("emphasis run preserved",
          ["No, no, no, that's wrong.", "It's very, very good."]) { out in
        out == ["No, no, no, that's wrong.", "It's very, very good."]
    }

    // Non-English training-data leaks (code-switching decodes emit the
    // leak phrases of THEIR language; the English-only list missed them).
    check("swedish training leaks dropped",
          ["Tack för att du tittade!", "Textning av BritneySpears88",
           "Undertexter från Amara.org-gemenskapen",
           "Vi bestämde oss för att skjuta upp lanseringen."]) { out in
        out == ["Vi bestämde oss för att skjuta upp lanseringen."]
    }
    check("german/french/spanish training leaks dropped",
          ["Vielen Dank fürs Zuschauen!", "Untertitel von Stephanie Geiges",
           "Sous-titres réalisés para la communauté d'Amara.org",
           "Gracias por ver el video.", "Le budget est approuvé."]) { out in
        out == ["Le budget est approuvé."]
    }
    // Real Swedish speech must never be over-cleaned by the new entries.
    check("swedish clean speech untouched",
          ["Tack för idag, vi hörs imorgon.", "Kan du skicka rapporten?",
           "Översättningen av avtalet är klar."]) { out in
        out == ["Tack för idag, vi hörs imorgon.", "Kan du skicka rapporten?",
                "Översättningen av avtalet är klar."]
    }

    // Per-language stitched batches (code-switching) hand the cleaner ~50%
    // less context per pass than a full track. Pin that the thresholds still
    // hold on short batches: the consecutive-loop rule (≥3) fires regardless
    // of batch length, and clean short batches survive untouched.
    check("short stitched batch: consecutive loop still collapses",
          ["Vi börjar nu.", "Tack.", "Tack.", "Tack.", "Tack.",
           "Då kör vi."]) { out in
        out.contains { $0.contains("repeated audio removed") }
        && out.first == "Vi börjar nu." && out.last == "Då kör vi."
        && out.filter { $0 == "Tack." }.count <= 1
    }
    check("short stitched batch: clean speech untouched",
          ["Kan du ta den?", "Ja, det gör jag.", "Bra, då säger vi så."]) { out in
        out == ["Kan du ta den?", "Ja, det gör jag.", "Bra, då säger vi så."]
    }
    // Known, deliberate limitation pinned: the interleaved-collapse window is
    // 10 lines, so an interleaved phrase inside a <10-segment batch is left
    // alone (conservative — never over-clean a short batch).
    check("short stitched batch: interleaved under window is preserved",
          ["Statusen är grön.", "Okej.", "Statusen är grön.",
           "Mm.", "Statusen är grön."]) { out in
        out.filter { $0 == "Statusen är grön." }.count == 3
    }

    // MARK: the silence gate — words cannot come from zeros

    /// A synthetic track: `loud` marks which 1-second slots carry audio.
    func envelope(_ loud: Set<Int>, seconds: Int) -> WavLevel.Envelope {
        WavLevel.Envelope(windowMs: 50,
                          peaks: (0..<(seconds * 20)).map { loud.contains($0 / 20) ? 9_000 : 0 })
    }
    func span(_ startMs: Int, _ endMs: Int, _ text: String) -> Transcriber.Segment {
        Transcriber.Segment(startMs: startMs, text: text, endMs: endMs)
    }
    func plain(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)  \(detail())") }
    }

    // The 2026-09-08 shape: a far-end track that is digitally silent whenever
    // nobody over there is talking, and a "Thank you." decoded onto one of
    // the holes.
    let realSpeech = [span(0, 2_000, "So how did the reorg land"),
                      span(2_000, 4_000, "It closed the whole department"),
                      span(6_000, 7_000, "Thank you."),
                      span(10_000, 12_000, "And then they offered me a package")]
    let track = envelope([0, 1, 2, 3, 10, 11], seconds: 13)
    let gated = TranscriptCleaner.clean(realSpeech, audio: track)
    plain("silence gate: a segment decoded from zeros is dropped",
          gated.segments.count == 3 && !gated.segments.contains { $0.text == "Thank you." }
          && gated.stats.silenced == 1,
          "got \(gated.segments.map(\.text))")

    plain("silence gate: real speech on the same track is untouched",
          gated.segments.map(\.text) == ["So how did the reorg land",
                                         "It closed the whole department",
                                         "And then they offered me a package"])

    plain("silence gate: without audio nothing is dropped",
          TranscriptCleaner.clean(realSpeech).segments.count == 4)

    plain("silence gate: a segment with no end timestamp is never judged",
          TranscriptCleaner.clean(
            [Transcriber.Segment(startMs: 6_000, text: "Thank you.")],
            audio: track).segments.count == 1)

    plain("silence gate: a span past the end of the WAV is missing evidence, not silence",
          TranscriptCleaner.clean([span(20_000, 22_000, "still talking")],
                                  audio: track).segments.count == 1)

    // A hallucination gets a *long* span — whisper hands the whole quiet
    // stretch to one invented line — and a lone blip inside it must not
    // rescue it. This is the case a peak test got wrong on the real call.
    let longHole = envelope([0, 1, 29], seconds: 30)
    plain("silence gate: one blip in a 25-second span does not make it speech",
          TranscriptCleaner.clean([span(2_000, 27_000, "Thank you.")],
                                  audio: longHole).stats.silenced == 1,
          "gate did not fire on a near-empty 25 s span")

    plain("silence gate: a segment that overlaps real speech is kept",
          TranscriptCleaner.clean([span(0, 3_000, "So how did the reorg land")],
                                  audio: longHole).stats.silenced == 0)

    // MARK: whisper's spans survive the cleaner

    // Diarization embeds these spans. Rebuilding them from the next segment's
    // start swallows the pause a speaker change lives in, so they have to
    // arrive intact rather than be inferred downstream.
    let spanned = TranscriptCleaner.clean([span(0, 1_800, "So how did the reorg land"),
                                           span(2_000, 3_900, "It closed the whole department")],
                                          audio: envelope([0, 1, 2, 3], seconds: 5))
    plain("spans: whisper's own endMs reaches the far side of the cleaner",
          spanned.segments.map(\.endMs) == [1_800, 3_900],
          "got \(spanned.segments.map(\.endMs))")

    plain("spans: a segment that never had an end still has none",
          TranscriptCleaner.clean([(startMs: 0, text: "no end here")])
            .segments.first?.endMs == nil)

    // The collapse marker stands for the whole run, so it has to span it —
    // otherwise the run's audio reads as a fraction of its real length.
    let looped = (0..<4).map { span($0 * 1_000, $0 * 1_000 + 900, "Yeah, yeah.") }
    let collapsed = TranscriptCleaner.clean(looped)
    plain("spans: the repeated-audio marker spans the whole run it replaces",
          collapsed.segments.count == 2
          && collapsed.segments[1].text.contains("repeated audio removed")
          && collapsed.segments[1].endMs == 3_900,
          "got \(collapsed.segments.map { ($0.text.prefix(20), $0.endMs) })")

    // MARK: the stretched-over-quiet rule — a mic track is never digitally silent

    /// A microphone track: every slot carries *something* (breath, the room),
    /// but only `loud` slots carry speech. Nothing here is ever zero, so the
    /// `isSilent` gate above can never fire on it — which is the 2026-09-11
    /// Zoom call, where six "Thank you."s survived a gate that had just
    /// dropped seven others.
    func micEnvelope(_ loud: Set<Int>, seconds: Int) -> WavLevel.Envelope {
        WavLevel.Envelope(windowMs: 50,
                          peaks: (0..<(seconds * 20)).map {
                              loud.contains($0 / 20) ? 9_000 : ($0 % 7 == 0 ? 300 : 40)
                          })
    }
    // 10% of windows over the threshold — measured on that call's quiet
    // stretches, which ran 5–13%.
    let micTrack = micEnvelope([0, 1, 2, 40, 41], seconds: 42)

    plain("stretched gate: a bare phrase over a quiet 30 s of mic track is dropped",
          TranscriptCleaner.clean([span(5_000, 35_000, "Thank you.")],
                                  audio: micTrack).stats.silenced == 1,
          "room tone kept a 30 s \"Thank you.\" alive")

    plain("stretched gate: the same phrase over its own speech is kept",
          TranscriptCleaner.clean([span(0, 2_000, "Thank you.")],
                                  audio: micTrack).stats.silenced == 0)

    plain("stretched gate: a short quiet segment is never judged by it",
          TranscriptCleaner.clean([span(5_000, 12_000, "Thank you.")],
                                  audio: micTrack).stats.silenced == 0,
          "a 7 s span is below stretchedSpanMs and must survive")

    // 12 words over 23 seconds at 18% active was the closest real segment in
    // the measurement; the threshold has to leave it alone.
    let sparseButReal = WavLevel.Envelope(
        windowMs: 50, peaks: (0..<(30 * 20)).map { $0 % 100 < 18 ? 9_000 : 40 })
    plain("stretched gate: sparse but real speech over a long span survives",
          TranscriptCleaner.clean(
            [span(0, 23_000, "Well, I consider it important, so I'm happy that you did that.")],
            audio: sparseButReal).stats.silenced == 0,
          "18% active is real speech, not a hallucination")

    plain("stretched gate: a long span past the end of the WAV is not judged",
          TranscriptCleaner.clean([span(60_000, 90_000, "Thank you.")],
                                  audio: micTrack).stats.silenced == 0)

        // Timestamps that disagree with the audio look exactly like a fully
    // hallucinated call. That is the case to refuse, not to act on.
    // Deliberately unalike, so only the gate could remove any of them.
    let distinct = ["the reorg closed our department", "so I took the package instead",
                    "Anne starts her new role in March", "we fly to Bologna on Sunday",
                    "the day rate lands around twenty five hundred",
                    "their valuation assumes tripling revenue", "no bot ever joins the call",
                    "Milo was held back a year", "the grant application was rejected",
                    "she is fundraising through the autumn", "the severance runs six months",
                    "we talked about the hackathon idea", "Bologna is two weeks of teaching",
                    "the convertible note was thirty thousand", "she missed the German grant",
                    "clinical trial referrals pay per lead", "the subscription model comes next",
                    "impostor syndrome came up a lot", "we should be sounding boards",
                    "he is speaking at the conference"]
    let allSilent = distinct.enumerated().map { span($0.offset * 1_000,
                                                     $0.offset * 1_000 + 900, $0.element) }
    let standDown = TranscriptCleaner.clean(allSilent, audio: envelope([], seconds: 30))
    plain("silence gate: stands down rather than delete a whole transcript",
          standDown.segments.count == distinct.count && standDown.stats.silenced == 0
          && standDown.stats.silenceGateStoodDown == distinct.count,
          standDown.stats.summary)

    print("\ntranscript-cleaner self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
