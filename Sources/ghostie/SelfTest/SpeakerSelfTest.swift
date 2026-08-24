import Foundation

/// Regression checks for speaker labelling: the feature pipeline the embedding
/// model is fed, the clustering that turns embeddings into speakers, and the
/// naming pass that puts real names on them.
///
/// Hermetic on purpose — no ONNX runtime, no 27 MB model, no audio fixtures.
/// The embeddings here are synthetic vectors with the *measured* geometry of
/// the real thing: on two recorded calls, same-speaker windows scored a mean
/// cosine of +0.73 (1st percentile +0.45) and different-speaker windows −0.06
/// (95th percentile +0.04). Clustering has to hold up on that shape.
func runSpeakerSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "\n      \(detail)")") }
    }

    // ---------------------------------------------------------------- Fbank
    check("fbank frame count matches Kaldi snip_edges",
          Fbank.frameCount(samples: 16_000) == 1 + (16_000 - 400) / 160
            && Fbank.frameCount(samples: 399) == 0
            && Fbank.frameCount(samples: 400) == 1,
          "got \(Fbank.frameCount(samples: 16_000)) for 1 s")
    check("povey window is a Hann raised to 0.85",
          Fbank.window.count == 400
            && abs(Fbank.window[0]) < 1e-6
            && abs(Fbank.window[199] - pow(0.5 - 0.5 * cos(2 * .pi * 199 / 399), 0.85)) < 1e-6)
    check("mel filters cover 80 bins, each with support",
          Fbank.filters.count == 80 && Fbank.filters.allSatisfy { !$0.weights.isEmpty })
    check("mel filters stay inside the FFT bins Kaldi uses",
          Fbank.filters.allSatisfy { $0.offset + $0.weights.count <= Fbank.numFFTBins })
    check("mel filters ascend in frequency",
          zip(Fbank.filters, Fbank.filters.dropFirst()).allSatisfy { $0.offset <= $1.offset })

    // A 440 Hz tone must put its energy in the low-frequency filters, and
    // silence must not produce a peak anywhere — the two ways a broken feature
    // pipeline shows up before the model ever sees it.
    let tone = (0..<16_000).map { Float(0.5 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
    if let (feats, frames) = Fbank.features(tone, subtractMean: false) {
        let mid = feats[(frames / 2) * 80 ..< (frames / 2 + 1) * 80]
        let peak = mid.enumerated().max { $0.element < $1.element }?.offset ?? -1
        // Kaldi's mel layout puts 440 Hz at bin (mel(440) - mel(20)) / delta - 1
        // ≈ 13.9 for 80 bins over 20 Hz–8 kHz, so the peak belongs at 13-15.
        check("440 Hz tone peaks in the mel bin Kaldi's layout puts it in",
              (12...16).contains(peak), "peak bin \(peak)")
        check("fbank emits one row of 80 per frame", feats.count == frames * 80)
    } else {
        check("fbank produced features for a 1 s tone", false)
    }
    check("fbank refuses a sub-frame input", Fbank.features([Float](repeating: 0, count: 100)) == nil)
    if let (centred, frames) = Fbank.features(tone, subtractMean: true), frames > 1 {
        var sum: Float = 0
        for f in 0..<frames { sum += centred[f * 80 + 40] }
        check("mean subtraction centres each bin over time", abs(sum / Float(frames)) < 1e-3,
              "residual mean \(sum / Float(frames))")
    }

    // ------------------------------------------------------- Voiced gating
    let silence = [Float](repeating: 0, count: 16_000)
    let quiet = (0..<16_000).map { _ in Float.random(in: -0.002...0.002) }
    check("digital silence is not voiced", !SpeakerEmbedder.isVoiced(silence))
    check("a noise floor is not voiced", !SpeakerEmbedder.isVoiced(quiet))
    check("a tone is voiced", SpeakerEmbedder.isVoiced(tone))
    // Half speech, half silence: still worth embedding.
    var half = Array(tone[0..<8_000]); half += [Float](repeating: 0, count: 8_000)
    check("half-speech window is voiced", SpeakerEmbedder.isVoiced(half))

    // ----------------------------------------------------------- Clustering
    /// Deterministic pseudo-random unit vectors, built so that vectors sharing
    /// a `speaker` land near a common centroid at the cosine distances the
    /// real model produces.
    func embedding(speaker: Int, index: Int, spread: Float) -> [Float] {
        var seed = UInt64(speaker &* 1_000_003 &+ index &* 7 &+ 11)
        // Centred on zero: a one-sided noise term would give every vector a
        // shared positive component and collapse the whole fixture into one
        // cluster, testing nothing.
        func rnd() -> Float {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Float(Int32(truncatingIfNeeded: Int(seed >> 33))) / Float(Int32.max) * 2 - 1
        }
        var v = [Float](repeating: 0, count: SpeakerEmbedder.embeddingDim)
        for i in v.indices { v[i] = rnd() * spread }
        // Each speaker owns a disjoint block of dimensions, which is what puts
        // different speakers near-orthogonal the way the real embeddings are.
        for i in 0..<32 { v[speaker * 32 + i] += 1 }
        return SpeakerEmbedder.normalized(v)
    }

    let d = SpeakerDiarizer()
    let twoSpeakers = (0..<12).map { embedding(speaker: $0 % 2, index: $0, spread: 0.35) }
    let clustered = d.agglomerate(twoSpeakers)
    check("two speakers cluster into two groups", Set(clustered).count == 2,
          "got \(Set(clustered).count)")
    check("two speakers cluster correctly",
          (0..<12).allSatisfy { clustered[$0] == clustered[$0 % 2] },
          "\(clustered)")

    let three = (0..<15).map { embedding(speaker: $0 % 3, index: $0, spread: 0.35) }
    check("three speakers cluster into three groups",
          Set(d.agglomerate(three)).count == 3, "\(d.agglomerate(three))")

    let one = (0..<10).map { embedding(speaker: 0, index: $0, spread: 0.35) }
    check("one speaker stays one cluster", Set(d.agglomerate(one)).count == 1,
          "\(d.agglomerate(one))")

    check("similarity of a vector with itself is 1",
          abs(SpeakerEmbedder.similarity(twoSpeakers[0], twoSpeakers[0]) - 1) < 1e-4)
    check("different speakers score below the merge threshold",
          1 - SpeakerEmbedder.similarity(embedding(speaker: 0, index: 1, spread: 0.35),
                                         embedding(speaker: 1, index: 2, spread: 0.35))
            > d.mergeThreshold)
    check("same speaker scores above the merge threshold",
          1 - SpeakerEmbedder.similarity(embedding(speaker: 0, index: 1, spread: 0.35),
                                         embedding(speaker: 0, index: 2, spread: 0.35))
            < d.mergeThreshold)

    // ------------------------------------------------------------ Smoothing
    check("a lone flip between agreeing neighbours is smoothed",
          d.smoothed([0, 0, 1, 0, 0]) == [0, 0, 0, 0, 0])
    check("a real turn change is not smoothed away",
          d.smoothed([0, 0, 1, 1, 0]) == [0, 0, 1, 1, 0])
    check("smoothing leaves gaps alone", d.smoothed([0, nil, 0]) == [0, nil, 0])
    check("smoothing handles a two-element input", d.smoothed([0, 1]) == [0, 1])

    // ------------------------------------------------------------ Gap filling
    check("a gap between one speaker's turns is that speaker",
          d.fillGaps([0, nil, nil, 0]) == [0, 0, 0, 0])
    check("a gap spanning a handover is split at the midpoint",
          d.fillGaps([0, nil, nil, 1]) == [0, 0, 1, 1])
    check("a leading gap takes the first known speaker",
          d.fillGaps([nil, nil, 1, 1]) == [1, 1, 1, 1])
    check("a trailing gap takes the last known speaker",
          d.fillGaps([0, 0, nil]) == [0, 0, 0])
    check("an all-unknown track is left alone",
          d.fillGaps([nil, nil]) == [nil, nil])

    // --------------------------------------------------------------- Naming
    let labels = ["Me", "Participant 1", "Participant 2"]
    check("a clean JSON reply is parsed",
          SpeakerNamer.parse(#"{"Me":"David","Participant 1":"Agneta","Participant 2":""}"#,
                             labels: labels) == ["Me": "David", "Participant 1": "Agneta"])
    check("a fenced reply with prose is parsed",
          SpeakerNamer.parse("Sure! ```json\n{\"Me\": \"David\"}\n```", labels: labels)
            == ["Me": "David"])
    check("junk yields no names", SpeakerNamer.parse("I could not tell.", labels: labels).isEmpty)
    check("labels that were not asked about are ignored",
          SpeakerNamer.parse(#"{"Participant 9":"Bob"}"#, labels: labels).isEmpty)
    check("two labels may share a name (an over-split speaker)",
          SpeakerNamer.parse(#"{"Participant 1":"Agneta","Participant 2":"Agneta"}"#,
                             labels: labels).count == 2)

    // The guard that matters: a model with no answer must not be allowed to
    // put a confident-looking role on a speaker.
    for bad in ["the advisor", "Speaker 2", "Participant 1", "unknown", "", "N/A",
                "A man who appears to be leading the call", "David (the client)",
                "  ", "client", "Me", "user 3"] {
        check("rejects \"\(bad)\" as a name", !SpeakerNamer.isPlausibleName(bad))
    }
    for good in ["David", "Agneta", "David Sjunnesson", "Anne-Marie", "Jean Luc Picard"] {
        check("accepts \"\(good)\" as a name", SpeakerNamer.isPlausibleName(good))
    }

    // ------------------------------------------------- Config-gated behaviour
    var off = Config(); off.nameSpeakers = false
    check("naming off returns no naming",
          SpeakerNamer(config: off).name(labels: labels, transcript: "hi") == nil)
    var mine = Config(); mine.nameSpeakers = true; mine.userName = "David"
    // A configured name is a fact and must apply without reaching any model.
    let selfOnly = SpeakerNamer(config: mine).name(labels: ["Me"], transcript: "hi")
    check("a configured userName names Me without a provider",
          selfOnly?.names == ["Me": "David"], "\(String(describing: selfOnly?.names))")

    print("speaker self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
