import Foundation

/// Regression check for the code-switching Smoother — the algorithmically
/// interesting, false-positive-prone part. Pure logic over synthetic
/// detections, so it needs no audio, no model, and no whisper on disk
/// (audio-fixture end-to-end checks live behind Tests/Fixtures and skip
/// gracefully when absent — see runCodeSwitchFixtureSelfTest).
func runCodeSwitchSelfTest() -> Bool {
    let cfg = CodeSwitchConfig()                  // sv/en, defaults
    func sm(_ window: Int) -> Smoother { Smoother(config: cfg, window: window) }
    let step = 1600, dur = 1500

    func det(_ i: Int, _ lang: String, conf: Double = 0.95,
             base: Int = 0) -> LanguageDetection {
        let s = base + i * step
        let seg = VADSegment(startMs: s, endMs: s + dur)
        if lang == "?" {
            return LanguageDetection(segment: seg, top: LanguageDetection.unknown,
                                     confidence: 0, margin: 0, logprobs: [:])
        }
        let other = lang == "sv" ? "en" : "sv"
        let lp = [lang: Foundation.log(conf), other: Foundation.log(1 - conf)]
        return LanguageDetection(segment: seg, top: lang, confidence: conf,
                                 margin: lp[lang]! - lp[other]!, logprobs: lp)
    }

    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)  \(detail())") }
    }

    let empty = LanguageTimeline(intervals: [])

    // Pass 1: a single-language track collapses to exactly one run.
    let svOnly = (0..<8).map { det($0, "sv") }
    let enOnly = (0..<8).map { det($0, "en") }
    let svRuns = sm(4).refine(svOnly, priorFrom: empty)
    let enRuns = sm(4).refine(enOnly, priorFrom: empty)
    check("sv_only → 1 sv run",
          svRuns.count == 1 && svRuns.first?.language == "sv",
          "got \(svRuns.map(\.language))")
    check("en_only → 1 en run",
          enRuns.count == 1 && enRuns.first?.language == "en",
          "got \(enRuns.map(\.language))")

    // Pass 1: mixed sv / en / sv with one en loanword inside the first sv
    // block → 3 runs (the lone loanword is absorbed by median + hysteresis).
    var mixed: [LanguageDetection] = []
    for i in 0..<6 { mixed.append(det(i, i == 2 ? "en" : "sv", conf: 0.9)) }
    for i in 6..<14 { mixed.append(det(i, "en")) }
    for i in 14..<20 { mixed.append(det(i, "sv")) }
    let mixedRuns = sm(4).refine(mixed, priorFrom: empty)
    check("mixed → 3 runs [sv,en,sv]",
          mixedRuns.map(\.language) == ["sv", "en", "sv"],
          "got \(mixedRuns.map(\.language)) (\(mixedRuns.count))")

    // Pass 2: Me has 2 ambiguous segments at t≈20s. Participants is
    // confidently English ending just before. The cross-track prior must
    // refine those segments to English…
    var me: [LanguageDetection] = []
    for i in 0..<4 { me.append(det(i, "sv")) }
    me.append(det(0, "?", base: 20_000)); me.append(det(1, "?", base: 20_000))
    for i in 0..<4 { me.append(det(i, "sv", base: 23_200)) }
    let partEn = (0..<5).map { det($0, "en", base: 12_000) }
    let partPrelim = sm(4).preliminary(partEn)
    let flipped = sm(4).refinedSegmentLabels(me, priorFrom: partPrelim)
    check("cross-track prior flips ambiguous Me segments to en",
          flipped[4] == "en" && flipped[5] == "en",
          "got \(flipped)")

    // …and with no nearby Participants speech, the same segments fall back
    // to the per-track decision (sv), not flipped.
    let isolated = sm(4).refinedSegmentLabels(me, priorFrom: empty)
    check("isolated ambiguous Me segments keep per-track sv",
          isolated[4] == "sv" && isolated[5] == "sv",
          "got \(isolated)")

    // Strength 0.5 makes Pass 2 a no-op (debug switch documented in config).
    var offCfg = CodeSwitchConfig(); offCfg.crossTrackPriorStrength = 0.5
    let neutral = Smoother(config: offCfg, window: 4)
        .refinedSegmentLabels(me, priorFrom: partPrelim)
    check("crossTrackPriorStrength 0.5 disables refinement",
          neutral[4] == "sv" && neutral[5] == "sv",
          "got \(neutral)")

    // Snap-to-silence (PR 4): adjacent runs get their boundary moved to the
    // nearest energy trough within snapSearchMs; otherwise they merge into
    // the longer run's language. Built on `AudioStitcher.troughs(...)` over
    // raw 16 kHz Int16-LE PCM — no models or fixtures required.
    do {
        // Synthesize 6 s of PCM: 2 s speech, 200 ms silence at 2.0–2.2,
        // 1.8 s speech, no silence, then 2 s speech to t=6 s.
        let sr = 16_000
        let speechAmp: Int16 = 8_000   // about -12 dBFS — well above the -40 floor
        func makePCM(speechRanges: [(start: Int, end: Int)],
                     totalMs: Int) -> Data {
            let totalSamples = totalMs * sr / 1000
            var samples = [Int16](repeating: 0, count: totalSamples)
            for r in speechRanges {
                let lo = r.start * sr / 1000, hi = min(totalSamples, r.end * sr / 1000)
                for i in lo..<hi {
                    // sine wave at 200 Hz with mild noise to give an RMS
                    // comfortably above the -40 dB floor.
                    let t = Double(i) / Double(sr)
                    let v = Foundation.sin(2 * .pi * 200 * t)
                    samples[i] = Int16(Double(speechAmp) * v)
                }
            }
            return samples.withUnsafeBufferPointer {
                Data(buffer: $0)
            }
        }

        // 0…2000 speech, 2000…2200 silence, 2200…4000 speech, 4000…6000 speech (no break).
        let pcm = makePCM(speechRanges: [(0, 2000), (2200, 4000), (4000, 6000)], totalMs: 6000)
        check("troughs: finds the 200 ms silence near 2.1 s",
              AudioStitcher.troughs(in: pcm, loMs: 1_300, hiMs: 2_900).contains { abs($0 - 2_100) < 100 },
              "troughs in 1300–2900ms: \(AudioStitcher.troughs(in: pcm, loMs: 1_300, hiMs: 2_900))")
        check("troughs: returns empty in continuous-speech region",
              AudioStitcher.troughs(in: pcm, loMs: 4_500, hiMs: 5_500).isEmpty)

        // Build two runs whose boundary lands inside the silence — snap should
        // move it to ~2100 ms.
        let runA = LanguageRun(language: "sv", startMs: 0, endMs: 2_300,
                               segments: [VADSegment(startMs: 0, endMs: 2_300)])
        let runB = LanguageRun(language: "en", startMs: 2_300, endMs: 6_000,
                               segments: [VADSegment(startMs: 2_300, endMs: 6_000)])
        let cst = CodeSwitchTranscriber(config: Config(),
                                        installed: InstalledModels(perLanguage: [:]))
        let snapped = cst.snapBoundaries([runA, runB], in: pcm)
        check("snap: boundary moves to trough center near 2.1 s",
              snapped.count == 2 && abs(snapped[0].endMs - 2_100) <= 100,
              "got endMs \(snapped.first?.endMs ?? -1)")
        check("snap: adjacent runs stay contiguous after snap",
              snapped.count == 2 && snapped[0].endMs == snapped[1].startMs)

        // No trough between two speech-only runs (continuous speech) → merge
        // into the longer language.
        let runC = LanguageRun(language: "sv", startMs: 4_000, endMs: 5_000,
                               segments: [VADSegment(startMs: 4_000, endMs: 5_000)])
        let runD = LanguageRun(language: "en", startMs: 5_000, endMs: 6_000,
                               segments: [VADSegment(startMs: 5_000, endMs: 6_000)])
        let merged = cst.snapBoundaries([runC, runD], in: pcm)
        check("snap: no trough → merge into longer run's language (sv wins)",
              merged.count == 1 && merged.first?.language == "sv"
              && merged.first?.startMs == 4_000 && merged.first?.endMs == 6_000,
              "got \(merged.map { "(\($0.language) \($0.startMs)-\($0.endMs))" })")

        // Snap must NOT use a silence trough that lives OUTSIDE the two runs.
        // PCM here is silent 0–2000 ms, then continuous speech 2000–6000 ms.
        // Two runs sit entirely inside the speech (a=2200–3000, b=3000–5000),
        // so the only silence (pre-2000) is out of span: the bounded search
        // finds no in-span trough and merges, rather than snapping a's end
        // back into the leading silence (which would invert the run and drop
        // its audio in stitch).
        let speechOnly = makePCM(speechRanges: [(2_000, 6_000)], totalMs: 6_000)
        let inA = LanguageRun(language: "sv", startMs: 2_200, endMs: 3_000,
                              segments: [VADSegment(startMs: 2_200, endMs: 3_000)])
        let inB = LanguageRun(language: "en", startMs: 3_000, endMs: 5_000,
                              segments: [VADSegment(startMs: 3_000, endMs: 5_000)])
        let bounded = cst.snapBoundaries([inA, inB], in: speechOnly)
        check("snap: trough outside the run span is never used (no inverted run)",
              bounded.allSatisfy { $0.endMs > $0.startMs }
              && (bounded.first?.startMs ?? -1) == 2_200,
              "got \(bounded.map { "(\($0.language) \($0.startMs)-\($0.endMs))" })")

        // Post-decode verification (PR 5): a stub LID reports high confidence
        // for "en" on every slice. A run routed as "sv" must re-route to "en"
        // when the margin exceeds verifyMarginDb. A run routed as "en" stays.
        struct StubVerifierLID: LanguageIdentifier {
            let top: String
            let topProb: Double
            var description: String { "stub-verifier" }
            func identify(pcm: Data, sampleRateHz: Int, restrict: [String]) throws -> [String: Double] {
                LogProb.skewed(toward: top, mass: topProb, over: restrict)
            }
        }
        var verifyCfg = Config()
        verifyCfg.codeSwitch.languages = ["sv", "en"]
        verifyCfg.codeSwitch.verifyMarginDb = 0.2
        let installedSvEn = InstalledModels(perLanguage: [
            "sv": "/stub/kb.bin", "en": "/stub/lv3.bin"
        ])
        let cstV = CodeSwitchTranscriber(
            config: verifyCfg,
            installed: installedSvEn,
            verifier: StubVerifierLID(top: "en", topProb: 0.9))
        let wrongSv = LanguageRun(language: "sv", startMs: 0, endMs: 3_000,
                                  segments: [VADSegment(startMs: 0, endMs: 3_000)])
        let rightEn = LanguageRun(language: "en", startMs: 3_000, endMs: 6_000,
                                  segments: [VADSegment(startMs: 3_000, endMs: 6_000)])
        let verified = cstV.verifyRunLanguages([wrongSv, rightEn], in: pcm)
        check("verify: high-margin disagreement re-routes the run",
              verified.count == 2 && verified[0].language == "en")
        check("verify: agreement keeps the original language",
              verified[1].language == "en")

        // Below the margin threshold (almost-uniform posterior) → no re-route.
        // 0.52 gives margin ≈ 0.08, well below the 0.20 threshold; 0.55
        // would land at 0.201 — right on the edge — and is misleading.
        let cstNeutral = CodeSwitchTranscriber(
            config: verifyCfg,
            installed: installedSvEn,
            verifier: StubVerifierLID(top: "en", topProb: 0.52))
        let neutral = cstNeutral.verifyRunLanguages([wrongSv], in: pcm)
        check("verify: low-margin LID → no re-route",
              neutral.count == 1 && neutral[0].language == "sv")

        // verifyMarginDb = 0 → verification disabled entirely.
        var offCfg = verifyCfg
        offCfg.codeSwitch.verifyMarginDb = 0
        let cstOff = CodeSwitchTranscriber(
            config: offCfg,
            installed: installedSvEn,
            verifier: StubVerifierLID(top: "en", topProb: 0.99))
        let untouched = cstOff.verifyRunLanguages([wrongSv], in: pcm)
        check("verify: verifyMarginDb=0 disables the pass",
              untouched.count == 1 && untouched[0].language == "sv")

        // A run whose language isn't in the active whitelist has no log-prob
        // to compare against in the posterior; the missing-key guard must KEEP
        // it rather than letting routedLp = -inf force an unconditional
        // re-route (margin would be +inf, past any verifyMarginDb gate).
        let deRun = LanguageRun(language: "de", startMs: 0, endMs: 3_000,
                                segments: [VADSegment(startMs: 0, endMs: 3_000)])
        let keptDe = cstV.verifyRunLanguages([deRun], in: pcm)   // verifier: en@0.9, active=[sv,en]
        check("verify: run language absent from posterior is kept, not force-rerouted",
              keptDe.count == 1 && keptDe[0].language == "de")
    }

    // 3-language Smoother (PR 3 contract: the binary cap is lifted; the same
    // refinement algorithm now handles N≥3 whitelists). A track that's
    // confidently `de` over 4 segments must collapse to one `de` run, and a
    // mixed sv→en→de track must produce three runs in order.
    do {
        var c3 = CodeSwitchConfig(); c3.languages = ["sv", "en", "de"]
        let sm3 = Smoother(config: c3, window: 4)
        func det3(_ i: Int, _ lang: String, base: Int = 0) -> LanguageDetection {
            let s = base + i * step
            let seg = VADSegment(startMs: s, endMs: s + dur)
            let conf = 0.95
            let other = (1 - conf) / 2.0
            let lp: [String: Double] = [
                "sv": Foundation.log(lang == "sv" ? conf : other),
                "en": Foundation.log(lang == "en" ? conf : other),
                "de": Foundation.log(lang == "de" ? conf : other)
            ]
            return LanguageDetection(segment: seg, top: lang, confidence: conf,
                                     margin: lp[lang]! - (lp.values.min() ?? 0),
                                     logprobs: lp)
        }
        let deOnly = (0..<6).map { det3($0, "de") }
        let r3 = sm3.refine(deOnly, priorFrom: empty)
        check("3-lang: de_only → 1 de run", r3.count == 1 && r3.first?.language == "de",
              "got \(r3.map(\.language))")

        var mix: [LanguageDetection] = []
        for i in 0..<6  { mix.append(det3(i, "sv")) }
        for i in 6..<14 { mix.append(det3(i, "en")) }
        for i in 14..<20 { mix.append(det3(i, "de")) }
        let rm = sm3.refine(mix, priorFrom: empty)
        check("3-lang: mixed sv→en→de → 3 runs in order",
              rm.map(\.language) == ["sv", "en", "de"],
              "got \(rm.map(\.language))")
    }

    // mostRecentEndingBefore is past-only (causality / timing-skew gotcha).
    let tl = LanguageTimeline(intervals: [
        .init(startMs: 0, endMs: 5_000, language: "en", confidence: 0.9),
        .init(startMs: 9_000, endMs: 12_000, language: "sv", confidence: 0.9)
    ])
    check("timeline lookup is past-only & window-bounded",
          tl.mostRecentEndingBefore(6_000, withinMs: 8_000) == "en"
          && tl.mostRecentEndingBefore(6_000, withinMs: 500) == nil
          && tl.mostRecentEndingBefore(8_000, withinMs: 8_000) == "en")

    // CodeSwitchConfig v3 migration: `languages: [String]` + `modelPerLanguage`
    // + `prompts` (and the pre-v2 `promptSv`/`promptEn` pair) all collapse into
    // `languages: [LanguageSetting]`. Every legacy shape must load without
    // losing user data — `Config.loadRaw()`'s `try?` turns any decoder slip
    // into a silent whole-config reset, so these are the highest-stakes checks
    // in the suite.
    do {
        let dec = JSONDecoder()
        func decode(_ json: String) -> CodeSwitchConfig {
            try! dec.decode(CodeSwitchConfig.self, from: Data(json.utf8))
        }

        // --- pre-v2: promptSv / promptEn, no languages list ----------------
        let v1 = decode(#"{"enabled":true,"promptSv":"SV-CUSTOM","promptEn":"EN-CUSTOM"}"#)
        check("v1: promptSv survives as prompt(for: sv)", v1.prompt(for: "sv") == "SV-CUSTOM")
        check("v1: promptEn survives as prompt(for: en)", v1.prompt(for: "en") == "EN-CUSTOM")
        check("v1: unknown language returns \"\" (no silent en fallback)",
              v1.prompt(for: "de") == "")
        check("v1: no languages list → still disk-driven (empty records)",
              v1.languages.isEmpty)

        // --- v2: prompts map, still no records -----------------------------
        let v2 = decode(#"{"prompts":{"sv":"NEW","de":"NEW-DE"},"promptSv":"IGNORED"}"#)
        check("v2: prompts map wins over the pre-v2 pair", v2.prompt(for: "sv") == "NEW")
        check("v2: prompts map honors N-language entries", v2.prompt(for: "de") == "NEW-DE")
        check("v2: unlisted language falls back to the built-in default",
              v2.prompt(for: "en").contains("Business call"))

        let bare = decode("{}")
        check("defaults: sv/en built-in prompts still apply with no config",
              bare.prompt(for: "sv").contains("svenska")
              && bare.prompt(for: "en").contains("Business call"))

        // --- v2 → v3: a bare code list becomes records ---------------------
        let v2list = decode(#"{"languages":["sv","en"]}"#)
        check("v2→v3: [\"sv\",\"en\"] decodes into two records in order",
              v2list.languages.map(\.code) == ["sv", "en"])
        check("v2→v3: migrated records take the auto-pick model",
              v2list.languages.allSatisfy { $0.model == nil })

        // --- v2 → v3: the two side-maps fold onto the records --------------
        let full = decode("""
        {"languages":["sv","en"],
         "modelPerLanguage":{"sv":"/my/own/swedish.bin"},
         "prompts":{"sv":"SV-P","en":"EN-P"}}
        """)
        check("v2→v3: a hand-edited modelPerLanguage folds into the record",
              full.setting(for: "sv")?.model == "/my/own/swedish.bin")
        check("v2→v3: prompts fold into the records",
              full.prompt(for: "sv") == "SV-P" && full.prompt(for: "en") == "EN-P")
        check("v2→v3: a language with no legacy model keeps the auto-pick",
              full.setting(for: "en")?.model == nil)

        // The shipped pre-v3 defaults are in EVERY existing config.json whether
        // or not the user chose them. Migrating them as explicit pins would
        // label two rows "pinned" that nobody pinned, and freeze them onto one
        // model forever.
        let shipped = decode("""
        {"languages":["sv","en"],
         "modelPerLanguage":{"sv":"kb-whisper-large","en":"whisper-large-v3"}}
        """)
        check("v2→v3: shipped default model names migrate to auto-pick, not pins",
              shipped.languages.allSatisfy { $0.model == nil })
        check("v2→v3: a legacy logical name still resolves when it IS a real pin",
              decode(#"{"languages":[{"code":"sv","model":"kb-whisper-large"}]}"#)
                  .modelPath(for: "sv") == Models.kbWhisperLarge(variant: "standard")?.destPath)

        // --- v3 native -----------------------------------------------------
        let v3 = decode("""
        {"languages":[{"code":"de","model":"ggml-de.bin","prompt":"DE-P"},{"code":"en"}]}
        """)
        check("v3: object records decode fully",
              v3.setting(for: "de")?.model == "ggml-de.bin"
              && v3.prompt(for: "de") == "DE-P")
        check("v3: a catalog filename resolves under the models dir",
              v3.modelPath(for: "de") == "\(Config.modelsDir)/ggml-de.bin")
        check("v3: an explicit empty prompt beats the built-in default",
              decode(#"{"languages":[{"code":"sv","prompt":""}]}"#).prompt(for: "sv") == "")
        check("v3: a record with no prompt still gets the built-in default",
              v3.languages.count == 2 && decode(#"{"languages":["sv"]}"#)
                  .prompt(for: "sv").contains("svenska"))
        check("v3: a junk record with no code is dropped, not kept as \"\"",
              decode(#"{"languages":[{"model":"x.bin"},{"code":"en"}]}"#)
                  .languages.map(\.code) == ["en"])

        // --- round trip: legacy keys are read once and never written back --
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let blob = String(data: try! enc.encode(full), encoding: .utf8) ?? ""
        check("re-encode: writes 'languages' records, drops every legacy key",
              blob.contains("\"languages\"")
              && blob.contains("\"code\":\"sv\"")
              && !blob.contains("promptSv") && !blob.contains("promptEn")
              && !blob.contains("modelPerLanguage") && !blob.contains("\"prompts\""))
        let reread = try! dec.decode(CodeSwitchConfig.self, from: Data(blob.utf8))
        check("re-encode: a save/load round trip is lossless",
              reread.setting(for: "sv")?.model == "/my/own/swedish.bin"
              && reread.prompt(for: "sv") == "SV-P"
              && reread.prompt(for: "en") == "EN-P"
              && reread.languages.map(\.code) == ["sv", "en"],
              blob)

        // A nil model must not be written as `null` — config.json is a file
        // people read and hand-edit.
        let sparse = String(data: try! enc.encode(decode(#"{"languages":["en"]}"#)),
                            encoding: .utf8) ?? ""
        check("re-encode: nil model/prompt are omitted, not null",
              !sparse.contains("null"), sparse)
    }

    // effectiveLanguages / effectiveModelPath: the v2 contract that the disk
    // is the whitelist. cs.languages can override (intersected against
    // what's installed); empty cs.languages means "use whatever is on disk".
    do {
        let installed3 = InstalledModels(perLanguage: [
            "sv": "/stub/kb.bin", "en": "/stub/lv3.bin", "de": "/stub/de.bin"
        ])
        let installed1 = InstalledModels(perLanguage: ["en": "/stub/lv3.bin"])
        let empty = InstalledModels(perLanguage: [:])

        var c = CodeSwitchConfig()           // languages: [] by default (disk-driven)
        check("default (empty) config → disk is the whitelist (all 3 installed)",
              c.effectiveLanguages(installed: installed3) == ["de", "en", "sv"])

        c.languages = ["sv", "en"]
        check("configured 2 + 3 installed → intersection (sv,en)",
              c.effectiveLanguages(installed: installed3) == ["sv", "en"])

        c.languages = ["sv", "sv", "en"]
        check("duplicate languages are de-duplicated (no Dictionary trap)",
              c.effectiveLanguages(installed: installed3) == ["sv", "en"])

        c.languages = []
        check("empty cs.languages + 3 installed → all 3 (disk is whitelist)",
              c.effectiveLanguages(installed: installed3) == ["de", "en", "sv"])

        c.languages = ["sv", "en", "de"]
        check("configured 3 + only en installed → just en",
              c.effectiveLanguages(installed: installed1) == ["en"])

        c.languages = ["sv", "en"]
        check("configured 2 + nothing installed → empty",
              c.effectiveLanguages(installed: empty) == [])

        // effectiveModelPath: a record's explicit model resolves on disk → wins.
        // Explicit model NOT on disk → fall through to the installed map.
        // Neither → nil.
        c.languages = [LanguageSetting(code: "en", model: "/dev/null")]  // exists
        check("explicit model that exists on disk wins over installed map",
              c.effectiveModelPath(for: "en", installed: installed1) == "/dev/null")

        c.languages = [LanguageSetting(code: "en", model: "/tmp/this-file-does-not-exist-xyzzy")]
        check("explicit model that doesn't exist falls through to installed",
              c.effectiveModelPath(for: "en", installed: installed1) == "/stub/lv3.bin")

        c.languages = []
        check("no explicit model + nothing installed for lang → nil",
              c.effectiveModelPath(for: "fr", installed: installed3) == nil)

        // A language served ONLY by an out-of-catalog absolute path stays in
        // the whitelist. Pre-v3 effectiveLanguages filtered on the installed
        // map alone, so it dropped the language here while effectiveModelPath
        // happily resolved it — the two disagreed.
        c.languages = [LanguageSetting(code: "fr", model: "/dev/null")]
        check("explicit out-of-catalog model keeps its language in the whitelist",
              c.effectiveLanguages(installed: installed3) == ["fr"])
        c.languages = []

        // effectiveDominant clamps a dominant with no installed model into the
        // whitelist, so off-whitelist runs never bucket into a language the
        // decode loop skips and the smoother prior never skews at zero mass.
        c.languages = []
        c.dominantLanguage = "de"          // not installed in installed1 (en only)
        check("effectiveDominant clamps an uninstalled dominant into the whitelist",
              c.effectiveDominant(installed: installed1) == "en")
        c.dominantLanguage = "en"
        check("effectiveDominant keeps an installed dominant",
              c.effectiveDominant(installed: installed3) == "en")
    }

    // Detection-driver capability: KB-Whisper (sv-biased) and base.en
    // (English-only) can't drive language detection / VAD even when installed;
    // large-v3 can; an unknown/custom path gets the benefit of the doubt.
    do {
        check("LID driver: base.en is not a balanced detection model",
              Models.isBadLIDDriver(path: Models.baseEnglish.destPath))
        check("LID driver: large-v3 is a balanced detection model",
              !Models.isBadLIDDriver(path: Models.largeV3.destPath))
        check("LID driver: KB-Whisper is sv-biased, not a detection model",
              Models.isBadLIDDriver(path: Models.kbWhisperLarge(variant: "standard")!.destPath))
        check("LID driver: an unknown/custom path is eligible",
              !Models.isBadLIDDriver(path: "/some/custom/multilingual.bin"))
    }

    // Single-language model preference: large-v3 → KB → base.en, so the
    // single-language path picks the best installed model (disk-driven) and
    // base.en is only the floor.
    do {
        let lv3 = Models.largeV3.destPath
        let kb = Models.kbWhisperLarge(variant: "standard")!.destPath
        let base = Models.baseEnglish.destPath
        check("single-lang model: large-v3 wins when present",
              Models.bestSingleLanguageModel { [lv3, kb, base].contains($0) } == lv3)
        check("single-lang model: KB beats base.en when large-v3 absent",
              Models.bestSingleLanguageModel { [kb, base].contains($0) } == kb)
        check("single-lang model: base.en is the floor",
              Models.bestSingleLanguageModel { $0 == base } == base)
        check("single-lang model: nothing installed → nil",
              Models.bestSingleLanguageModel { _ in false } == nil)
    }

    // Summary-model picker: tier aliases instead of pinned versions, so the
    // list can't fall behind Anthropic's releases. The load-bearing property is
    // that the picker always contains — and selects — whatever is configured:
    // the old code called `selectItem(withTitle:)`, which fails *silently* on a
    // miss, so an unlisted model left the menu displaying a different one.
    do {
        check("models: the shipped default is an alias, not a pinned version",
              ClaudeModels.isAlias(Config().summaryModel)
              && ClaudeModels.isAlias(ClaudeModels.defaultModel))
        check("models: no alias id looks like a pinned version",
              ClaudeModels.aliases.allSatisfy { !$0.id.contains("-") && !$0.id.hasPrefix("claude") },
              "got \(ClaudeModels.aliases.map(\.id))")

        // An alias selects its own row and offers no stray pinned entry.
        let sonnet = ClaudeModels.menu(configured: "sonnet")
        check("models: an alias selects its own row",
              sonnet.entries[sonnet.selected] == .alias("sonnet"))
        check("models: an alias adds no pinned row",
              !sonnet.entries.contains { if case .pinned = $0 { return true }; return false })
        check("models: every menu ends with the custom escape hatch",
              sonnet.entries.last == .custom)

        // A model this build has never heard of — the exact case that used to
        // silently mis-display — must appear and be selected.
        let future = ClaudeModels.menu(configured: "claude-sonnet-7-20270101")
        check("models: an unknown/newer model still appears in the picker",
              future.entries.contains(.pinned("claude-sonnet-7-20270101")))
        check("models: …and is the selected row, not a lookalike",
              future.entries[future.selected] == .pinned("claude-sonnet-7-20270101"))
        check("models: a retired pinned id is likewise preserved, not dropped",
              ClaudeModels.menu(configured: "claude-3-opus-20240229")
                  .entries.contains(.pinned("claude-3-opus-20240229")))

        // Selection must never land on `.custom` (choosing it opens a prompt).
        for configured in ["sonnet", "opus", "haiku", "fable", "claude-sonnet-5", "", "   "] {
            let m = ClaudeModels.menu(configured: configured)
            check("models: selection is a real row for \"\(configured)\"",
                  m.selected >= 0 && m.selected < m.entries.count && m.entries[m.selected] != .custom)
        }
        check("models: an empty config falls back to the default row",
              ClaudeModels.menu(configured: "").entries[
                  ClaudeModels.menu(configured: "").selected] == .alias(ClaudeModels.defaultModel))
        check("models: whitespace is trimmed, not treated as a pinned id",
              ClaudeModels.menu(configured: "  sonnet  ").entries[
                  ClaudeModels.menu(configured: "  sonnet  ").selected] == .alias("sonnet"))

        // The description tells the truth about what pinning costs.
        check("models: an alias is described as following the latest",
              ClaudeModels.summary(for: "opus").contains("automatically"))
        check("models: a pinned version warns it stops following releases",
              ClaudeModels.summary(for: "claude-sonnet-5").contains("won't move")
              && ClaudeModels.summary(for: "claude-sonnet-5").contains("claude-sonnet-5"))
    }

    // Model catalog: the user-extensible "bring your own model" layer. The
    // pipeline is already language-agnostic, so these check that a custom
    // catalog entry flows through discovery / capability lookups the same way
    // a built-in does — keyed by language, honoring goodForLID. Pure (no disk).
    do {
        let seeds = ModelCatalog.builtinSeeds()
        let ar = CatalogEntry(filename: "ggml-ar.bin", url: "https://example.test/ar.bin",
                              label: "Arabic specialist", language: "ar",
                              goodForLID: false, approxBytes: 3_000_000_000)
        let customMulti = CatalogEntry(filename: "ggml-custom-multi.bin",
                                       url: "https://example.test/m.bin",
                                       label: "Custom multilingual", language: "xx",
                                       goodForLID: true, approxBytes: 1_000_000_000)

        // merge: a new filename is appended; a duplicate filename is collapsed.
        let merged = ModelCatalog.merge(seeds: seeds, user: [ar])
        check("catalog merge: a custom entry is appended",
              merged.count == seeds.count + 1 && merged.contains { $0.filename == "ggml-ar.bin" })
        let dupName = CatalogEntry(filename: "ggml-ar.bin", url: "https://example.test/other.bin",
                                   label: "dup", language: "ar")
        check("catalog merge: duplicate custom filenames collapse to one",
              ModelCatalog.merge(seeds: seeds, user: [ar, dupName]).filter { $0.filename == "ggml-ar.bin" }.count == 1)

        // merge: a built-in's goodForLID can be re-flagged, but its url/size
        // stay authoritative (a sparse hand edit can't corrupt the URL).
        let flip = ModelCatalog.merge(seeds: seeds,
            user: [CatalogEntry(filename: Models.baseEnglish.filename, url: "", label: "", goodForLID: true)])
        let baseMerged = flip.first { $0.filename == Models.baseEnglish.filename }
        check("catalog merge: a built-in goodForLID re-flags, url stays authoritative",
              baseMerged?.goodForLID == true
              && baseMerged?.url == Models.baseEnglish.url.absoluteString
              && flip.count == seeds.count)

        // installed(): a custom entry registers its own language.
        let inst = Models.installed(from: [ar], preferredKBVariant: "standard") { $0 == ar.model()!.destPath }
        check("catalog installed(): a custom entry registers its language",
              inst.modelPath(for: "ar") == ar.model()!.destPath)

        // A custom goodForLID model is a valid detection driver; a custom
        // specialist (goodForLID: false) is ruled out — same rule as base.en/KB.
        let decoders = Models.decodeModels(from: [customMulti, ar])
        check("catalog: a custom goodForLID model is a valid LID driver",
              !Models.isBadLIDDriver(path: customMulti.model()!.destPath, in: decoders))
        check("catalog: a custom specialist is ruled out as an LID driver",
              Models.isBadLIDDriver(path: ar.model()!.destPath, in: decoders))

        // Single-language pick prioritizes goodForLID over raw size (the
        // multilingual model wins even though the specialist is larger).
        check("catalog: single-language pick prefers a goodForLID model over a larger specialist",
              Models.bestSingleLanguageModel(from: [ar, customMulti]) { _ in true } == customMulti.model()!.destPath)
    }

    // LanguageSetup: the single resolver the Settings pane, `doctor` and the
    // add/remove flows all read. Pure — `present` is the on-disk test — so the
    // whole UI's state is checkable here without a filesystem.
    do {
        let lv3 = CatalogEntry(from: Models.largeV3, builtin: true)
        let kb = CatalogEntry(from: Models.kbWhisperLarge(variant: "standard")!,
                              builtin: true, kbVariant: "standard")
        let base = CatalogEntry(from: Models.baseEnglish, builtin: true)
        let vad = CatalogEntry(from: Models.sileroVAD, builtin: true)
        let de = CatalogEntry(filename: "ggml-de.bin", url: "https://example.test/de.bin",
                              label: "German specialist", language: "de",
                              goodForLID: false, approxBytes: 900_000_000)
        let catalog = [lv3, kb, base, vad, de]
        func path(_ e: CatalogEntry) -> String { e.model()!.destPath }
        func onDisk(_ entries: [CatalogEntry]) -> (String) -> Bool {
            let paths = Set(entries.map(path))
            return { paths.contains($0) }
        }

        // Nothing installed, nothing configured.
        let bare = LanguageSetup.resolve(config: Config(), catalog: catalog,
                                         present: onDisk([]))
        check("setup: nothing installed → unconfigured, no rows",
              bare.rows.isEmpty && bare.mode == .unconfigured && !bare.isConfigured)

        // Disk-driven: two models on disk, no config. Rows come from the disk
        // and the mode is code-switching.
        let disk2 = LanguageSetup.resolve(config: Config(), catalog: catalog,
                                          present: onDisk([lv3, kb, vad]))
        check("setup: disk-driven install lists what's installed",
              disk2.rows.map(\.code) == ["en", "sv"] && !disk2.isConfigured,
              "got \(disk2.rows.map(\.code))")
        check("setup: two installed languages → code-switch mode",
              disk2.mode == .codeSwitch(["en", "sv"]))
        check("setup: large-v3 is named as the detection driver",
              disk2.detectionModelLabel == Models.largeV3.label
              && disk2.rows.first { $0.code == "en" }?.drivesDetection == true)
        check("setup: the KB row is not claiming to drive detection",
              disk2.rows.first { $0.code == "sv" }?.drivesDetection == false)
        check("setup: a healthy 2-language install has no warnings",
              disk2.warnings.isEmpty, "got \(disk2.warnings)")

        // The failure the old UI never mentioned: two languages, but the only
        // models are a Swedish-biased head and a German specialist, so nothing
        // can tell them apart.
        var noLID = Config()
        noLID.codeSwitch.languages = ["sv", "de"]
        noLID.whisperModel = "/nonexistent"
        let degraded = LanguageSetup.resolve(config: noLID, catalog: catalog,
                                             present: onDisk([kb, de, vad]))
        check("setup: no balanced multilingual model → noDetectionModel warning",
              degraded.warnings.contains(.noDetectionModel)
              && degraded.detectionModelLabel == nil,
              "got \(degraded.warnings)")
        check("setup: degraded routing still lists both languages as ready",
              degraded.rows.allSatisfy { $0.state == .onDisk })

        // VAD is load-bearing for code-switching and silent when absent.
        let noVAD = LanguageSetup.resolve(config: Config(), catalog: catalog,
                                          present: onDisk([lv3, kb]))
        check("setup: code-switching without Silero VAD warns",
              noVAD.warnings.contains(.vadMissing), "got \(noVAD.warnings)")
        check("setup: one language + no VAD does not warn (single pass doesn't need it)",
              !LanguageSetup.resolve(config: Config(), catalog: catalog,
                                     present: onDisk([base])).warnings.contains(.vadMissing))

        // A configured language whose model isn't downloaded: shown, flagged,
        // and NOT counted as active — so the mode reflects reality. Needs a
        // disk with no multilingual model, or large-v3 would cover German
        // (which is the point of the coverage checks further down).
        var pending = Config()
        pending.codeSwitch.languages = ["sv", "de"]
        let half = LanguageSetup.resolve(config: pending, catalog: catalog,
                                         present: onDisk([kb, vad]))
        check("setup: configured-but-missing language is listed, not silently dropped",
              half.rows.map(\.code) == ["sv", "de"])
        check("setup: its state is .missing and it warns",
              half.rows.last?.state == .missing
              && half.warnings.contains(.modelMissing(code: "de")),
              "got \(String(describing: half.rows.last?.state)) \(half.warnings)")
        check("setup: a missing model doesn't count toward code-switch mode",
              half.mode == .single("sv"), "got \(half.mode)")
        check("setup: the row still names the model it would download",
              half.rows.last?.modelFilename == "ggml-de.bin")

        // A language nothing in the catalog can decode. With a multilingual
        // model in the catalog this state is nearly unreachable — which is the
        // improvement — so it takes a specialists-only catalog to produce.
        var unknown = Config()
        unknown.codeSwitch.languages = ["en", "ja"]
        let noModel = LanguageSetup.resolve(config: unknown, catalog: [kb, base, vad],
                                            present: onDisk([base, vad]))
        check("setup: language nothing can decode → .none + noModelForLanguage",
              noModel.rows.last?.state == LanguageSetup.ModelState.none
              && noModel.warnings.contains(.noModelForLanguage(code: "ja")),
              "got \(String(describing: noModel.rows.last?.state)) \(noModel.warnings)")

        // An explicitly pinned model beats the auto-pick and says so.
        var pinned = Config()
        pinned.codeSwitch.languages = [LanguageSetting(code: "en", model: base.filename)]
        let pinnedSetup = LanguageSetup.resolve(config: pinned, catalog: catalog,
                                                present: onDisk([lv3, base, vad]))
        check("setup: an explicit model wins over the better auto-pick",
              pinnedSetup.rows.first?.modelFilename == base.filename
              && pinnedSetup.rows.first?.modelIsExplicit == true)

        // dominantLanguage surfaces as exactly one primary row.
        var dom = Config()
        dom.codeSwitch.languages = ["sv", "en"]
        dom.codeSwitch.dominantLanguage = "sv"
        let domSetup = LanguageSetup.resolve(config: dom, catalog: catalog,
                                             present: onDisk([lv3, kb, vad]))
        check("setup: exactly one row is primary, and it's the dominant language",
              domSetup.rows.filter(\.isPrimary).map(\.code) == ["sv"])

        // materialized / adding / removing — the three edit primitives the
        // Settings flows share, so "grow the whitelist" can't be forgotten at
        // a call site the way it was in two places pre-v3.
        let seeded = LanguageSetup.materialized(config: Config(), catalog: catalog,
                                                present: onDisk([lv3, kb]))
        check("materialize: an unconfigured install seeds from disk",
              seeded.map(\.code) == ["en", "sv"], "got \(seeded.map(\.code))")
        var already = Config()
        already.codeSwitch.languages = [LanguageSetting(code: "de", prompt: "KEEP")]
        check("materialize: a configured install is returned untouched",
              LanguageSetup.materialized(config: already, catalog: catalog,
                                         present: onDisk([lv3])).map(\.code) == ["de"])

        let grown = LanguageSetup.adding("de", model: "ggml-de.bin", to: seeded)
        check("adding: appends a new language with its model",
              grown.map(\.code) == ["en", "sv", "de"] && grown.last?.model == "ggml-de.bin")
        let repointed = LanguageSetup.adding("en", model: base.filename, to: grown)
        check("adding: re-adding an existing language re-points it in place",
              repointed.map(\.code) == ["en", "sv", "de"]
              && repointed.first?.model == base.filename)
        let keepsPrompt = LanguageSetup.adding(
            "de", model: "other.bin", to: [LanguageSetting(code: "de", prompt: "KEEP")])
        check("adding: changing the model keeps the language's prompt",
              keepsPrompt.first?.prompt == "KEEP" && keepsPrompt.first?.model == "other.bin")

        check("removing: drops the language",
              LanguageSetup.removing("sv", from: grown)?.map(\.code) == ["en", "de"])
        check("removing: the last language returns nil so the caller can explain",
              LanguageSetup.removing("en", from: ["en"]) == nil)
    }

    // Multilingual coverage: one large-v3 is the default decoder for every
    // language without a specialist, so German/Spanish work with no extra
    // download. The load-bearing constraint is that this must NOT widen the
    // disk-driven whitelist — installing large-v3 can't mean "Ghostie now
    // listens for 99 languages".
    do {
        let lv3 = CatalogEntry(from: Models.largeV3, builtin: true)
        let turbo = CatalogEntry(from: Models.largeV3Turbo, builtin: true)
        let kb = CatalogEntry(from: Models.kbWhisperLarge(variant: "standard")!,
                              builtin: true, kbVariant: "standard")
        let base = CatalogEntry(from: Models.baseEnglish, builtin: true)
        let vad = CatalogEntry(from: Models.sileroVAD, builtin: true)
        let catalog = [lv3, turbo, kb, base, vad]
        func path(_ e: CatalogEntry) -> String { e.model()!.destPath }
        func onDisk(_ es: [CatalogEntry]) -> (String) -> Bool {
            let s = Set(es.map(path)); return { s.contains($0) }
        }

        check("catalog: large-v3 declares multilingual, KB and base.en do not",
              lv3.multilingual && turbo.multilingual && !kb.multilingual && !base.multilingual)
        check("catalog: decodes() covers any Whisper language for a multilingual model",
              lv3.decodes("de") && lv3.decodes("es") && lv3.decodes("en"))
        check("catalog: a specialist decodes only its own language",
              kb.decodes("sv") && !kb.decodes("de"))
        check("catalog: decodes() rejects a code Whisper can't emit",
              !lv3.decodes("klingon") && !lv3.decodes(""))
        check("catalog: VAD decodes nothing", !vad.decodes("en") && !vad.decodes("sv"))

        // The recommendation for a language with no specialist.
        check("recommended: German falls to large-v3 (no per-language model needed)",
              ModelCatalog.recommended(for: "de", in: catalog, kbVariant: "standard")?.filename
                  == Models.largeV3.filename)
        check("recommended: Spanish likewise",
              ModelCatalog.recommended(for: "es", in: catalog, kbVariant: "standard")?.filename
                  == Models.largeV3.filename)
        check("recommended: a specialist still beats the generalist for its language",
              ModelCatalog.recommended(for: "sv", in: catalog, kbVariant: "standard")?.filename
                  == Models.kbWhisperLarge(variant: "standard")!.filename)
        check("entries(for:): German is offered both multilingual models, turbo second",
              ModelCatalog.entries(for: "de", in: catalog, kbVariant: "standard").map(\.filename)
                  == [Models.largeV3.filename, Models.largeV3Turbo.filename])
        check("entries(for:): Swedish lists KB first, then the generalists",
              ModelCatalog.entries(for: "sv", in: catalog, kbVariant: "standard").first?.filename
                  == Models.kbWhisperLarge(variant: "standard")!.filename)

        // A user-added specialist must outrank the generalist for its language.
        let deSpecialist = CatalogEntry(filename: "ggml-de.bin", url: "https://example.test/de.bin",
                                        label: "German specialist", language: "de",
                                        approxBytes: 900_000_000)
        check("entries(for:): a user's German specialist outranks large-v3 for German",
              ModelCatalog.entries(for: "de", in: catalog + [deSpecialist],
                                   kbVariant: "standard").first?.filename == "ggml-de.bin")

        // THE constraint: multilingual models must not widen `languages`.
        let inst = Models.installed(from: catalog, preferredKBVariant: "standard",
                                    present: onDisk([lv3, kb, vad]))
        check("installed: the disk-driven whitelist stays the specialists only",
              inst.languages == ["en", "sv"], "got \(inst.languages)")
        check("installed: modelPath is nil for a language nothing specializes in",
              inst.modelPath(for: "de") == nil)
        check("installed: decodePath falls back to the multilingual model",
              inst.decodePath(for: "de") == Models.largeV3.destPath)
        check("installed: decodePath prefers a specialist over the generalist",
              inst.decodePath(for: "sv") == Models.kbWhisperLarge(variant: "standard")!.destPath)
        check("installed: no multilingual model on disk → no fallback",
              Models.installed(from: catalog, preferredKBVariant: "standard",
                               present: onDisk([kb, base])).decodePath(for: "de") == nil)

        // End to end: configuring German with only large-v3 + KB installed.
        var withDE = Config()
        withDE.codeSwitch.languages = ["sv", "en", "de"]
        check("config: German resolves to the installed large-v3, no download",
              withDE.codeSwitch.effectiveModelPath(for: "de", installed: inst,
                                                   present: onDisk([lv3, kb, vad]))
                  == Models.largeV3.destPath)
        check("config: all three languages are effective",
              withDE.codeSwitch.effectiveLanguages(installed: inst,
                                                   present: onDisk([lv3, kb, vad]))
                  == ["sv", "en", "de"])
        let deSetup = LanguageSetup.resolve(config: withDE, catalog: catalog,
                                            present: onDisk([lv3, kb, vad]))
        check("setup: German shows Ready on the large-v3 already installed",
              deSetup.rows.first { $0.code == "de" }?.state == .onDisk
              && deSetup.rows.first { $0.code == "de" }?.modelFilename == Models.largeV3.filename)
        check("setup: three languages, no warnings, detection still resolved",
              deSetup.mode == .codeSwitch(["sv", "en", "de"])
              && deSetup.warnings.isEmpty
              && deSetup.detectionModelLabel == Models.largeV3.label,
              "got \(deSetup.warnings)")
        check("setup: an UNCONFIGURED install with large-v3 still lists only en+sv",
              LanguageSetup.resolve(config: Config(), catalog: catalog,
                                    present: onDisk([lv3, kb, vad])).rows.map(\.code) == ["en", "sv"])
        check("required: German adds nothing to fetch when large-v3 is present",
              Models.required(for: withDE, catalog: catalog, installed: inst)
                  .map(\.filename)
                  .filter { $0 != Models.speakerEmbedding.filename }.sorted()
                  == [Models.kbWhisperLarge(variant: "standard")!.filename,
                      Models.largeV3.filename, Models.sileroVAD.filename].sorted())
    }

    // Models.required: derived from the CONFIGURED languages, not a hardcoded
    // sv+en pair. Pre-v3 any 2-language setup reported KB-Whisper + large-v3,
    // so a German+English user got 1.1 GB of Swedish auto-downloaded on launch.
    do {
        let lv3 = CatalogEntry(from: Models.largeV3, builtin: true)
        let kb = CatalogEntry(from: Models.kbWhisperLarge(variant: "standard")!,
                              builtin: true, kbVariant: "standard")
        let base = CatalogEntry(from: Models.baseEnglish, builtin: true)
        let vad = CatalogEntry(from: Models.sileroVAD, builtin: true)
        let de = CatalogEntry(filename: "ggml-de.bin", url: "https://example.test/de.bin",
                              label: "German", language: "de", approxBytes: 900_000_000)
        let catalog = [lv3, kb, base, vad, de]
        let nothing = InstalledModels(perLanguage: [:])

        func allNames(_ ms: [Model]) -> [String] { ms.map(\.filename) }
        // The checks below are about which *speech* models get fetched, so the
        // speaker-embedding model is filtered out of them and asserted on its
        // own terms further down.
        func names(_ ms: [Model]) -> [String] {
            allNames(ms).filter { $0 != Models.speakerEmbedding.filename }
        }

        var deEn = Config()
        deEn.codeSwitch.languages = ["de", "en"]
        let req = Models.required(for: deEn, catalog: catalog, installed: nothing)
        check("required: de+en asks for the German and English models, never KB",
              names(req).contains("ggml-de.bin")
              && names(req).contains(Models.largeV3.filename)
              && !names(req).contains(Models.kbWhisperLarge(variant: "standard")!.filename),
              "got \(names(req))")
        check("required: VAD is always included", names(req).contains(Models.sileroVAD.filename))
        check("required: the LID driver is NOT force-required (it's a Settings warning)",
              names(req).count == 3, "got \(names(req))")

        check("required: a fresh install bootstraps base.en, not a 2 GB pair",
              names(Models.required(for: Config(), catalog: catalog, installed: nothing))
                  == [Models.baseEnglish.filename, Models.sileroVAD.filename])

        check("required: unconfigured but sv installed → the Swedish model, not base.en",
              names(Models.required(for: Config(), catalog: catalog,
                                    installed: InstalledModels(perLanguage: ["sv": "/x"])))
                  == [Models.kbWhisperLarge(variant: "standard")!.filename,
                      Models.sileroVAD.filename])

        var pinned = Config()
        pinned.codeSwitch.languages = [LanguageSetting(code: "en", model: base.filename)]
        check("required: an explicitly pinned model is what gets fetched",
              names(Models.required(for: pinned, catalog: catalog, installed: nothing))
                  == [Models.baseEnglish.filename, Models.sileroVAD.filename])

        // Speaker embeddings ride along by default — 27 MB is what makes
        // diarization work on a fresh install rather than being a flag to find.
        check("required: the speaker model is fetched when diarization is on",
              allNames(Models.required(for: Config(), catalog: catalog, installed: nothing))
                  .contains(Models.speakerEmbedding.filename))
        var noDiar = Config(); noDiar.diarization = false
        check("required: the speaker model is skipped when diarization is off",
              !allNames(Models.required(for: noDiar, catalog: catalog, installed: nothing))
                  .contains(Models.speakerEmbedding.filename))
    }

    // LanguageIdentifier seam: WhisperLID parse + spread, and the segmenter's
    // posterior → detection conversion. These exercise the v2 protocol seam
    // without spinning up whisper-cli or any audio fixtures.
    do {
        check("parse: 'auto-detected language: sv (p = 0.87)'",
              WhisperLID.parse("whisper_full_with_state: auto-detected language: sv (p = 0.87)\n")
                ?? ("?", 0) == ("sv", 0.87))
        check("parse: 'detected language: en' (no probability)",
              WhisperLID.parse("detected language: en\n")?.0 == "en")
        check("parse: missing line → nil",
              WhisperLID.parse("nothing here\n") == nil)

        let spread = WhisperLID.spread(top: "sv", confidence: 0.85, restrict: ["sv", "en"])
        check("spread: top in restrict → log(0.85) on top, log(0.15) on other",
              abs((spread["sv"] ?? 0) - Foundation.log(0.85)) < 1e-9
              && abs((spread["en"] ?? 0) - Foundation.log(0.15)) < 1e-9)

        let off = WhisperLID.spread(top: "fr", confidence: 0.9, restrict: ["sv", "en"])
        check("spread: off-whitelist top → uniform log(0.5) each",
              abs((off["sv"] ?? 0) - Foundation.log(0.5)) < 1e-9
              && abs((off["en"] ?? 0) - Foundation.log(0.5)) < 1e-9)

        // Anti-inversion clamp: whisper's confidence is over its full
        // ~100-language softmax, so a weak top-1 (p = 0.2) re-spread over a
        // 2-language whitelist used to become en 0.2 / sv 0.8 — evidence
        // AGAINST the LID's own pick. The top must keep a strict edge.
        let weak = WhisperLID.spread(top: "en", confidence: 0.2, restrict: ["sv", "en"])
        check("spread: weak top-1 keeps a strict edge over uniform (no inversion)",
              (weak["en"] ?? -1) > (weak["sv"] ?? 0)
              && abs(Foundation.exp(weak["en"] ?? 0) - 0.55) < 1e-9)

        // detection(from:whitelist:segment:): the static helper that
        // LanguageSegmenter uses to wrap an identifier's posterior into the
        // LanguageDetection shape the smoother consumes.
        let seg = VADSegment(startMs: 0, endMs: 2_000)
        let post: [String: Double] = ["sv": Foundation.log(0.9), "en": Foundation.log(0.1)]
        let detSv = LanguageSegmenter.detection(from: post, whitelist: ["sv", "en"], segment: seg)
        check("detection: top reads from posterior argmax",
              detSv.top == "sv"
              && abs(detSv.confidence - 0.9) < 1e-9
              && abs(detSv.margin - (Foundation.log(0.9) - Foundation.log(0.1))) < 1e-9)

        let allInf: [String: Double] = ["sv": -.infinity, "en": -.infinity]
        let detUnk = LanguageSegmenter.detection(from: allInf, whitelist: ["sv", "en"], segment: seg)
        check("detection: all -Inf → unknown",
              detUnk.top == LanguageDetection.unknown)

        let detOff = LanguageSegmenter.detection(from: ["fr": Foundation.log(0.95)],
                                                 whitelist: ["sv", "en"], segment: seg)
        check("detection: top not in whitelist → unknown",
              detOff.top == LanguageDetection.unknown)

        // Stub identifier round-trip: the segmenter's contract is "throwing
        // identifier → unknown for that segment", not the whole call.
        struct ThrowingLID: LanguageIdentifier {
            var description: String { "throwing-stub" }
            func identify(pcm: Data, sampleRateHz: Int, restrict: [String]) throws -> [String: Double] {
                throw NSError(domain: "test", code: 1)
            }
        }
        struct StubLID: LanguageIdentifier {
            let post: [String: Double]
            var description: String { "stub" }
            func identify(pcm: Data, sampleRateHz: Int, restrict: [String]) throws -> [String: Double] {
                post
            }
        }
        check("LID protocol covariance: stub implements identify",
              ((try? StubLID(post: ["sv": Foundation.log(0.9)]).identify(
                  pcm: Data(), sampleRateHz: 16_000, restrict: ["sv", "en"]))?["sv"] ?? 0)
              == Foundation.log(0.9))
        check("LID protocol: throwing impl propagates",
              (try? ThrowingLID().identify(pcm: Data(), sampleRateHz: 16_000, restrict: [])) == nil)
    }

    // ServerWhisperLID's pure helpers (the resident whisper-server LID).
    // verbose_json gotcha (verified on whisper.cpp 1.8.4): `detected_language`
    // is the FULL ENGLISH NAME ("english"), never a code — everything comes
    // from `language_probabilities` (a thresholded map summing to < 1),
    // folded through the look-alike remap and renormalized over the
    // whitelist. No process, network, or models here.
    do {
        let en = #"{"task":"transcribe","detected_language":"english","detected_language_probability":0.9937,"language_probabilities":{"en":0.9937,"ja":0.0014,"sv":0.0008},"text":""}"#
        let full = ServerWhisperLID.parseProbabilities(Data(en.utf8))
        check("server parse: full probability map with lowercased ISO-code keys",
              abs((full?["en"] ?? 0) - 0.9937) < 1e-9
              && abs((full?["ja"] ?? 0) - 0.0014) < 1e-9
              && abs((full?["sv"] ?? 0) - 0.0008) < 1e-9,
              "got \(String(describing: full))")

        let noMap = #"{"detected_language":"english","detected_language_probability":0.99}"#
        check("server parse: missing language_probabilities → nil (name is never parsed)",
              ServerWhisperLID.parseProbabilities(Data(noMap.utf8)) == nil)

        // Errors come back as HTTP 400 with a PLAIN TEXT body, not JSON.
        check("server parse: plain-text error body ('Invalid request') → nil",
              ServerWhisperLID.parseProbabilities(Data("Invalid request".utf8)) == nil)

        // restrictedPosterior: fold → argmax → whitelist renormalize.
        let fold: (String) -> String = {
            ["no", "nb", "nn", "da"].contains($0) ? "sv" : $0
        }
        // Top-1 is "en" (0.40), but folded Swedish mass (0.32+0.10+0.15=0.57)
        // wins — the case a top-1-only remap could never catch.
        let nordic: [String: Double] = ["en": 0.40, "no": 0.32, "da": 0.10, "sv": 0.15]
        let rpN = ServerWhisperLID.restrictedPosterior(nordic, remap: fold,
                                                       restrict: ["sv", "en"])
        check("server posterior: look-alike mass folds BEFORE the argmax (en top-1 → sv)",
              rpN?.top == "sv"
              && abs(Foundation.exp(rpN?.logprobs["sv"] ?? 0) - 0.57 / 0.97) < 1e-9
              && abs(Foundation.exp(rpN?.logprobs["en"] ?? 0) - 0.40 / 0.97) < 1e-9,
              "got \(String(describing: rpN))")

        // …and the flip side, which is why the ONNX LID is built WITHOUT the
        // remap (`LanguageSegmenter.defaultIdentifier`). Over VoxLingua107's
        // 107 classes, English audio leaves `en` clearly on top while four
        // sibling Nordic classes each hold a little — and folding all four
        // into `sv` out-votes it. Measured shape from the 2026-08-28
        // all-English call: p(en)=0.52, Nordic mass 0.07 spread over no/nb/
        // nn/da, p(sv)=0.00. Whisper's peakier head doesn't do this, so the
        // fold stays on there and off here.
        let englishSpread: [String: Double] = ["en": 0.20, "no": 0.09, "nb": 0.08,
                                               "nn": 0.07, "da": 0.06, "sv": 0.004]
        check("server posterior: folding four sibling classes out-votes a clear top-1",
              ServerWhisperLID.restrictedPosterior(englishSpread, remap: fold,
                                                   restrict: ["sv", "en"])?.top == "sv")
        check("server posterior: without the fold the same spread stays English",
              ServerWhisperLID.restrictedPosterior(englishSpread, remap: { $0 },
                                                   restrict: ["sv", "en"])?.top == "en")

        // Real competing mass reaches the smoother: sv 0.5 / en 0.3 must
        // renormalize to 0.625 / 0.375, not collapse to top-1 + residual.
        let mixed: [String: Double] = ["sv": 0.5, "en": 0.3, "de": 0.15]
        let rpM = ServerWhisperLID.restrictedPosterior(mixed, remap: { $0 },
                                                       restrict: ["sv", "en"])
        check("server posterior: whitelist masses renormalize (0.5/0.3 → 0.625/0.375)",
              rpM?.top == "sv"
              && abs(Foundation.exp(rpM?.logprobs["sv"] ?? 0) - 0.625) < 1e-9
              && abs(Foundation.exp(rpM?.logprobs["en"] ?? 0) - 0.375) < 1e-9)

        // Off-whitelist winner surfaces as `top` so identify can throw and the
        // segment falls to the unknown floor instead of being force-labeled.
        let german: [String: Double] = ["de": 0.7, "sv": 0.1, "en": 0.05]
        check("server posterior: off-whitelist argmax is surfaced, not swallowed",
              ServerWhisperLID.restrictedPosterior(german, remap: { $0 },
                                                   restrict: ["sv", "en"])?.top == "de")

        // A whitelist language absent from the thresholded map gets the 1e-3
        // floor: the posterior carries every whitelist key with finite mass.
        let solo: [String: Double] = ["sv": 0.95]
        let rpS = ServerWhisperLID.restrictedPosterior(solo, remap: { $0 },
                                                       restrict: ["sv", "en"])
        let enLp = rpS?.logprobs["en"] ?? -.infinity
        check("server posterior: absent whitelist language floors at 1e-3, never -inf",
              rpS?.top == "sv" && enLp > -.infinity
              && abs(Foundation.exp(enLp) - 0.001 / 0.951) < 1e-9)

        // Multipart body: the three verified fields, proper boundary framing.
        let body = String(data: ServerWhisperLID.multipartBody(
            wav: Data("RIFFstub".utf8), boundary: "B"), encoding: .utf8) ?? ""
        check("server multipart: carries file + detect_language + verbose_json",
              body.contains("name=\"file\"") && body.contains("RIFFstub")
              && body.contains("name=\"detect_language\"\r\n\r\ntrue")
              && body.contains("name=\"response_format\"\r\n\r\nverbose_json")
              && body.hasSuffix("--B--\r\n"))
    }

    // Long-segment chunking for detection: a switch inside one long VAD
    // segment used to be invisible (one label from the first 30 s).
    do {
        let long = VADSegment(startMs: 1_000, endMs: 21_000)   // 20 s
        let chunks = LanguageSegmenter.splitForDetect(long, maxMs: 8_000)
        let contiguous = zip(chunks, chunks.dropFirst()).allSatisfy { $0.endMs == $1.startMs }
        check("splitForDetect: 20 s → 3 contiguous chunks covering exactly",
              chunks.count == 3 && contiguous
              && chunks.first?.startMs == 1_000 && chunks.last?.endMs == 21_000,
              "got \(chunks)")
        check("splitForDetect: every chunk ≤ maxMs and > maxMs/2 (stays above detect floor)",
              chunks.allSatisfy { $0.durationMs <= 8_000 && $0.durationMs > 4_000 })

        let short = VADSegment(startMs: 0, endMs: 5_000)
        check("splitForDetect: at-or-under maxMs comes back untouched",
              LanguageSegmenter.splitForDetect(short, maxMs: 8_000) == [short])
        check("splitForDetect: exactly maxMs is not split",
              LanguageSegmenter.splitForDetect(VADSegment(startMs: 0, endMs: 8_000),
                                               maxMs: 8_000).count == 1)
    }

    // Monolingual fast path: the sampled short-circuit that skips per-segment
    // LID when a spread-out probe says the whole track is one language. A
    // false positive routes a whole track to the wrong model, so these pin
    // the "unanimous or nothing" contract rather than just the happy path.
    do {
        func probe(_ lang: String, margin: Double = 3.0) -> LanguageDetection {
            let seg = VADSegment(startMs: 0, endMs: 2_000)
            if lang == "?" {
                return LanguageDetection(segment: seg, top: LanguageDetection.unknown,
                                         confidence: 0, margin: 0, logprobs: [:])
            }
            let other = lang == "sv" ? "en" : "sv"
            return LanguageDetection(segment: seg, top: lang, confidence: 0.95,
                                     margin: margin,
                                     logprobs: [lang: Foundation.log(0.95),
                                                other: Foundation.log(0.05)])
        }
        func verdict(_ probes: [LanguageDetection]) -> String? {
            LanguageSegmenter.monolingualVerdict(
                probes,
                minSamples: LanguageSegmenter.monoProbeMinSamples,
                minMargin: LanguageSegmenter.monoProbeMinMargin,
                maxUnknownFraction: LanguageSegmenter.monoProbeMaxUnknown)
        }

        check("monolingualVerdict: unanimous confident sample → that language",
              verdict((0..<24).map { _ in probe("en") }) == "en")
        check("monolingualVerdict: one dissenting probe vetoes the whole sample",
              verdict((0..<23).map { _ in probe("en") } + [probe("sv")]) == nil)
        check("monolingualVerdict: too few samples never decides",
              verdict((0..<(LanguageSegmenter.monoProbeMinSamples - 1))
                        .map { _ in probe("en") }) == nil)
        check("monolingualVerdict: one weak-margin probe vetoes",
              verdict((0..<23).map { _ in probe("en") } + [probe("en", margin: 0.2)]) == nil)
        check("monolingualVerdict: a few unknowns still decide",
              verdict((0..<20).map { _ in probe("sv") }
                      + (0..<4).map { _ in probe("?") }) == "sv")
        check("monolingualVerdict: too many unknowns disqualify the sample",
              verdict((0..<12).map { _ in probe("sv") }
                      + (0..<12).map { _ in probe("?") }) == nil)
        check("monolingualVerdict: an all-unknown sample never decides",
              verdict((0..<24).map { _ in probe("?") }) == nil)

        // probeIndices: even spread, eligibility floor, no over-sampling.
        let many = (0..<100).map { VADSegment(startMs: $0 * 3_000, endMs: $0 * 3_000 + 2_000) }
        let idx = LanguageSegmenter.probeIndices(many, minDetectMs: 1_500, count: 24)
        let gaps = zip(idx, idx.dropFirst()).map { $1 - $0 }
        check("probeIndices: samples the requested count, in order, no repeats",
              idx.count == 24 && idx == idx.sorted() && Set(idx).count == 24,
              "got \(idx)")
        check("probeIndices: spread evenly across the whole track",
              idx.first! < 6 && idx.last! > 93 && gaps.allSatisfy { $0 >= 3 && $0 <= 5 },
              "first \(idx.first!) last \(idx.last!) gaps \(Set(gaps).sorted())")
        check("probeIndices: skips segments under the detect floor",
              LanguageSegmenter.probeIndices(
                [VADSegment(startMs: 0, endMs: 500),
                 VADSegment(startMs: 1_000, endMs: 4_000),
                 VADSegment(startMs: 5_000, endMs: 5_400)],
                minDetectMs: 1_500, count: 24) == [1])
        check("probeIndices: fewer eligible than requested returns them all",
              LanguageSegmenter.probeIndices(Array(many.prefix(10)),
                                             minDetectMs: 1_500, count: 24).count == 10)
        check("probeIndices: count 0 samples nothing",
              LanguageSegmenter.probeIndices(many, minDetectMs: 1_500, count: 0).isEmpty)
    }

    // Fine (sliding-window) LID pass: CUSUM change-point scan over synthetic
    // posterior timelines — the mock the followups doc asked for.
    do {
        func win(_ startMs: Int, _ lang: String, strength: Double = 0.95) -> (segment: VADSegment, logprobs: [String: Double]) {
            let other = lang == "sv" ? "en" : "sv"
            return (VADSegment(startMs: startMs, endMs: startMs + 1_500),
                    [lang: Foundation.log(strength), other: Foundation.log(1 - strength)])
        }
        // Clean single language → no change points.
        let mono = (0..<8).map { win($0 * 500, "sv") }
        check("changePoints: single language → none",
              LanguageSegmenter.changePoints(windows: mono, minDwellMs: 1_500).isEmpty)

        // Clear sustained switch at 4000 ms → one boundary exactly there.
        let switched = (0..<8).map { win($0 * 500, "sv") }
            + (8..<16).map { win($0 * 500, "en") }
        check("changePoints: sustained switch cuts at the excursion start",
              LanguageSegmenter.changePoints(windows: switched, minDwellMs: 1_500) == [4_000],
              "got \(LanguageSegmenter.changePoints(windows: switched, minDwellMs: 1_500))")

        // One-window blip → dwell never reached, no cut.
        var blip = (0..<10).map { win($0 * 500, "sv") }
        blip[5] = win(5 * 500, "en")
        check("changePoints: single-window blip never cuts",
              LanguageSegmenter.changePoints(windows: blip, minDwellMs: 1_500).isEmpty)

        // Ambiguous stretch (≈ 50/50) → evidence never accumulates, no cut.
        let mushy = (0..<6).map { win($0 * 500, "sv") }
            + (6..<12).map { win($0 * 500, "en", strength: 0.52) }
        check("changePoints: weak evidence never crosses the threshold",
              LanguageSegmenter.changePoints(windows: mushy, minDwellMs: 1_500).isEmpty)

        // Three languages, two sustained switches → two cuts in order.
        func win3(_ startMs: Int, _ lang: String) -> (segment: VADSegment, logprobs: [String: Double]) {
            var lp = ["sv": Foundation.log(0.025), "en": Foundation.log(0.025), "de": Foundation.log(0.025)]
            lp[lang] = Foundation.log(0.95)
            return (VADSegment(startMs: startMs, endMs: startMs + 1_500), lp)
        }
        let tri = (0..<6).map { win3($0 * 500, "sv") }
            + (6..<12).map { win3($0 * 500, "en") }
            + (12..<18).map { win3($0 * 500, "de") }
        check("changePoints: three languages → two ordered cuts",
              LanguageSegmenter.changePoints(windows: tri, minDwellMs: 1_500) == [3_000, 6_000],
              "got \(LanguageSegmenter.changePoints(windows: tri, minDwellMs: 1_500))")

        // aggregate: product of posteriors renormalizes to a valid posterior.
        let agg = LanguageSegmenter.aggregate([
            ["sv": Foundation.log(0.8), "en": Foundation.log(0.2)],
            ["sv": Foundation.log(0.6), "en": Foundation.log(0.4)],
        ])
        let aggSum = agg.map { $0.values.reduce(0) { $0 + Foundation.exp($1) } } ?? 0
        check("aggregate: renormalized posterior sums to 1 with the right top",
              abs(aggSum - 1) < 1e-9 && agg?.max(by: { $0.value < $1.value })?.key == "sv",
              "sum=\(aggSum)")
        check("aggregate: empty input is nil", LanguageSegmenter.aggregate([]) == nil)
    }

    // Fine-pass integration: detect() on one 10 s segment whose PCM encodes
    // the language in its sample values (first-sample sniffing stub), under
    // a low-latency identifier. The coarse label would average the switch
    // away; the fine pass must split it near 5 s.
    do {
        struct PositionStub: LanguageIdentifier {
            var description: String { "position stub" }
            var isLowLatency: Bool { true }
            func identify(pcm: Data, sampleRateHz: Int,
                          restrict: [String]) throws -> [String: Double] {
                // First Int16 sample: 100 → sv, 200 → en (the test PCM sets
                // every sample in a region to the region's marker value).
                let first = pcm.withUnsafeBytes { $0.load(as: Int16.self) }
                let lang = first == 100 ? "sv" : "en"
                var lp: [String: Double] = [:]
                for l in restrict {
                    lp[l] = Foundation.log(l == lang ? 0.95 : 0.05 / Double(max(1, restrict.count - 1)))
                }
                return lp
            }
        }
        var cfg = Config()
        cfg.codeSwitch.languages = ["sv", "en"]
        let installed = InstalledModels(perLanguage: ["sv": "/x", "en": "/y"])
        let seg = LanguageSegmenter(config: cfg, installed: installed,
                                    identifier: PositionStub())
        let bytesPerMs = 32
        var pcm = Data(capacity: 10_000 * bytesPerMs)
        for ms in 0..<10_000 {
            let v: Int16 = ms < 5_000 ? 100 : 200
            for _ in 0..<16 { withUnsafeBytes(of: v.littleEndian) { pcm.append(contentsOf: $0) } }
        }
        let dets = try! seg.detect([VADSegment(startMs: 0, endMs: 10_000)], pcm: pcm)
        let langs = dets.map(\.top)
        let hasCutNear5s = dets.contains { $0.segment.startMs >= 4_500 && $0.segment.startMs <= 5_500 }
        check("fine pass: intra-chunk switch splits near the true boundary",
              langs.contains("sv") && langs.contains("en") && hasCutNear5s && dets.count >= 2,
              "got \(dets.map { "\($0.top)@\($0.segment.startMs)-\($0.segment.endMs)" })")
        check("fine pass: sv precedes en in timeline order",
              langs.firstIndex(of: "sv")! < langs.firstIndex(of: "en")!)
    }

    // AudioStitcher: stitch + offset-table round trip — the timestamp-fidelity
    // path every decoded code-switch segment travels back through. Synthetic
    // zero PCM (the table only cares about geometry); temp-dir WAV, no models.
    do {
        let stitcher = AudioStitcher()
        let pcm = Data(count: 3 * 16_000 * 2)   // 3 s of 16 kHz mono Int16 silence
        let runs = [
            // Deliberately unsorted: stitch must order by startMs.
            LanguageRun(language: "en", startMs: 2_000, endMs: 3_000, segments: []),
            LanguageRun(language: "sv", startMs: 0, endMs: 1_000, segments: []),
        ]
        let dest = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ghostie-selftest-stitch.wav")
        defer { try? FileManager.default.removeItem(at: dest) }
        do {
            let s = try stitcher.stitch(pcm: pcm, runs: runs, to: dest, silencePadMs: 500)
            // Layout: sv 0–1000, pad 1000–1500, en 1500–2500.
            check("stitch: two entries, ordered by original start",
                  s.table.entries.count == 2
                  && s.table.entries[0].originalStartMs == 0
                  && s.table.entries[1].originalStartMs == 2_000,
                  "got \(s.table.entries)")
            check("stitch: toOriginal maps inside runs exactly",
                  s.table.toOriginal(500) == 500
                  && s.table.toOriginal(1_500) == 2_000
                  && s.table.toOriginal(2_499) == 2_999,
                  "got \(String(describing: s.table.toOriginal(500))) \(String(describing: s.table.toOriginal(1_500))) \(String(describing: s.table.toOriginal(2_499)))")
            check("stitch: silence pad and past-end map to nil (dropped)",
                  s.table.toOriginal(1_200) == nil && s.table.toOriginal(2_500) == nil)
            let payload = try AudioStitcher.readPCM(s.url)
            check("stitch: WAV payload is runs + one pad (2.5 s)",
                  payload.count == (1_000 + 500 + 1_000) * 32,
                  "got \(payload.count) bytes")
        } catch {
            check("stitch: round trip threw", false, "\(error)")
        }
    }

    // Pipeline.merge: deterministic cross-track ordering. Equal timestamps
    // (concurrent cross-talk) used to order arbitrarily between runs because
    // Swift's sort is not stable.
    do {
        let lines = [
            Pipeline.Line(startMs: 2_000, speaker: "Participants", text: "b"),
            Pipeline.Line(startMs: 1_000, speaker: "Participants", text: "same-time"),
            Pipeline.Line(startMs: 1_000, speaker: "Me", text: "same-time"),
            Pipeline.Line(startMs: 0, speaker: "Me", text: "a"),
        ]
        let merged = Pipeline.merge(lines)
        check("merge: sorted by startMs with Me-first tie-break",
              merged.map { "\($0.startMs)/\($0.speaker)" }
                  == ["0/Me", "1000/Me", "1000/Participants", "2000/Participants"],
              "got \(merged.map { "\($0.startMs)/\($0.speaker)" })")
        check("merge: deterministic under input reversal",
              Pipeline.merge(lines.reversed()).map { "\($0.startMs)/\($0.speaker)" }
                  == merged.map { "\($0.startMs)/\($0.speaker)" })
    }

    // dedupeBoundaries: run-boundary echoes (same words decoded by both
    // adjacent per-language runs) are dropped; distant repeats are kept.
    do {
        let cst = CodeSwitchTranscriber(config: Config(),
                                        installed: InstalledModels(perLanguage: [:]))
        typealias S = Transcriber.Segment
        let echoed = cst.dedupeBoundaries([
            S(startMs: 0, text: "vi ses imorgon"),
            S(startMs: 800, text: "vi ses imorgon"),         // boundary echo
            S(startMs: 5_000, text: "så det gör vi"),
            S(startMs: 5_400, text: "gör vi imorgon"),        // both boundary tokens overlap
            S(startMs: 6_000, text: "then we will decide"),   // 1-of-2 overlap with prev: kept
            S(startMs: 30_000, text: "vi ses imorgon"),       // far repeat: legit
        ])
        check("dedupeBoundaries: adjacent + boundary-token echoes dropped, weak overlap and far repeat kept",
              echoed.map(\.startMs) == [0, 5_000, 6_000, 30_000],
              "got \(echoed.map(\.startMs))")
    }

    // Optional end-to-end audio fixtures (Tests/Fixtures) — skipped cleanly
    // when not present so `ghostie selftest` stays green without 2 GB models.
    let fixtures = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Tests/Fixtures")
    if FileManager.default.fileExists(atPath: fixtures.path) {
        print("  · Tests/Fixtures present — audio end-to-end checks would run here")
    } else {
        print("  · (audio fixtures absent — skipping end-to-end codeswitch checks)")
    }

    print("\ncode-switching self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
