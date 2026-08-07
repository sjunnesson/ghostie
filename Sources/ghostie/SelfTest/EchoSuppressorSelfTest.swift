import Foundation

/// Built-in regression check for the cross-track echo guard. Fixtures are
/// lifted from a real 2026-08-07 speakerphone call where every remote
/// sentence appeared on both tracks (raw mic tap re-capturing the speakers),
/// so the shapes below — pure echo, mixed real+echo segments, ASR variance
/// between the two decodes of the same audio — are the genuine article.
func runEchoSuppressorSelfTest() -> Bool {
    typealias Seg = (startMs: Int, text: String)
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "\n      \(detail)")") }
    }

    // ---- Echo call (no headphones): remote speech present on both tracks.
    let part: [Seg] = [
        (51_000, "sorry god i don't know why the phone has to connect to the computer like why do i need this"),
        (59_000, "multi-level you know like you know it's like the orchestra experience when you're receiving a call"),
        (66_000, "right it's like you know and i feel like there's this overall"),
        (76_000, "connection happening like you know people just kind trying to like just minimize the amount of"),
        (82_000, "technology in their space and like clear it out you know it's uh it's it's nice honestly i'm never"),
        (119_000, "deep analysis sorry I need to turn this off I had a deep analysis of um of the brief and uh yeah I"),
        (129_000, "think it'd be great to kind of like discuss a few things obviously um you know on on my end there's"),
        (136_000, "obviously a sticker shock experience because uh it's just beyond what we're capable of doing right"),
        (206_000, "yeah"),
        (210_000, "Perhaps. Yeah, yeah."),
    ]
    let echoedMe: [Seg] = [
        // Pure echo of the remote speaker (speakers → mic).
        (52_000, "i don't know why the phone has to connect to the computer like why do i need this multi-level"),
        (60_000, "you know like you know it's like the orchestra experience when you're receiving a call"),
        // Mixed: my real words, then the remote's reply bleeding in.
        (66_000, "yeah it's uh too many systems trying to be too clever right right it's like you know and i feel"),
        // Echo with ASR variance between the two decodes ("deconnection").
        (74_000, "like there's this overall deconnection happening like you know people just kind trying to like just"),
        // Genuinely mine — nothing nearby on the other track.
        (105_000, "well it's it's a risk aversion right uh they want to see that you can deliver"),
        (110_000, "so i guess it's less on the on the the question of the uh of the product by itself"),
        // Mixed: my words + echo of the remote mid-sentence.
        (120_000, "um so great to connect i had a really deep analysis sorry i need to turn this up"),
        // Echo spanning two Participants segments.
        (123_000, "i had a deep analysis of um of the brief and uh yeah i think it would be great to kind of like"),
        // Genuinely mine again.
        (206_000, "but it's uh the question is in a way is is you and the team uh because the b2b the reason why i'm"),
    ]

    let (out, stats) = EchoSuppressor.suppress(me: echoedMe, participants: part)
    let texts = out.map { $0.text }
    check("echo call engages", stats.engaged, stats.summary)
    check("pure echo segments dropped",
          !texts.contains { $0.contains("phone has to connect") }
          && !texts.contains { $0.contains("orchestra experience") },
          "out: \(texts)")
    check("mixed segment keeps my half, loses the echo tail",
          texts.contains { $0.contains("too many systems trying to be too clever") }
          && !texts.contains { $0.contains("you know and i feel") },
          "out: \(texts)")
    check("echo with ASR variance dropped (residue rule)",
          !texts.contains { $0.contains("deconnection") },
          "out: \(texts)")
    check("genuine Me speech survives verbatim",
          texts.contains("well it's it's a risk aversion right uh they want to see that you can deliver")
          && texts.contains { $0.contains("because the b2b") },
          "out: \(texts)")
    check("stats add up",
          stats.dropped > 0 && stats.trimmed > 0
          && out.count == echoedMe.count - stats.dropped,
          "dropped \(stats.dropped), trimmed \(stats.trimmed), out \(out.count)")

    let (out2, _) = EchoSuppressor.suppress(me: echoedMe, participants: part)
    check("deterministic (same input, same output)",
          out2.map { $0.text } == texts && out2.map { $0.startMs } == out.map { $0.startMs })

    // ---- Headphone call: same speakers, zero cross-track duplication.
    let cleanMe: [Seg] = [
        (52_000, "yeah it's uh too many systems trying to be too clever right"),
        (66_000, "tech for the purpose but not tech for the sake of tech right"),
        (84_000, "yeah it's finding finding those balances right and uh"),
        (105_000, "well it's it's a risk aversion right uh they want to see that you can deliver"),
        (110_000, "so i guess it's less on the on the the question of the uh of the product by itself"),
        (123_000, "i've been sitting on the other side at ikea and asking the same thing to startups"),
        (131_000, "it's risk management right you want to be unique and delivering unique experience"),
        (140_000, "but you also want to make sure that you deliberate so i think that is my perspective on it"),
    ]
    let (cleanOut, cleanStats) = EchoSuppressor.suppress(me: cleanMe, participants: part)
    check("headphone call untouched",
          !cleanStats.engaged && cleanOut.map { $0.text } == cleanMe.map { $0.text },
          cleanStats.summary)

    // ---- One genuinely mirrored phrase stays below the engage threshold:
    // on a non-echo call, verbal mirroring must never be trimmed.
    var mirroredMe = cleanMe
    mirroredMe.append((150_000, "school is free in sweden also so that is not the problem"))
    var mirroredPart = part
    mirroredPart.append((152_000, "school is free in sweden also also nice yeah exactly"))
    let (mirrorOut, mirrorStats) = EchoSuppressor.suppress(me: mirroredMe, participants: mirroredPart)
    check("occasional mirroring below threshold — untouched",
          !mirrorStats.engaged && mirrorOut.map { $0.text } == mirroredMe.map { $0.text },
          mirrorStats.summary)

    // ---- Solo recording: nothing on the Participants track.
    let (soloOut, soloStats) = EchoSuppressor.suppress(me: cleanMe, participants: [])
    check("solo recording untouched",
          !soloStats.engaged && soloOut.map { $0.text } == cleanMe.map { $0.text })

    print("\necho-suppressor self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
