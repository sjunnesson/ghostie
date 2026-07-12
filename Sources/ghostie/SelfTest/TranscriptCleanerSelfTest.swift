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

    print("\ntranscript-cleaner self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
