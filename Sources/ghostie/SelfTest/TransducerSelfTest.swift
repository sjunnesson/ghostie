import Foundation

/// Regression check for the transducer decode path — everything around the
/// model that is not inference: tokens into words and segments, audio into
/// pieces, and the language routing read off the transcript. No model, no
/// ONNX Runtime and no recognizer needed.
///
/// The routing cases are the real ones from 2026-11-11: an all-English call
/// on which the Swedish model wrote "Thank you so much." as "Tack så mycket.",
/// and a Swedish call on which acoustic language ID had called a run of
/// "Ja." / "Mm." English.
func runTransducerSelfTest() -> Bool {
    var passed = 0, failed = 0
    func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok { passed += 1; print("  ✓ \(name)") }
        else { failed += 1; print("  ✗ \(name)\(detail.isEmpty ? "" : "\n      \(detail)")") }
    }
    typealias Token = TransducerModel.Token

    // MARK: Tokens → words
    let vocab = ["<unk>", "\u{2581}hej", "\u{2581}d", "å", ",", "\u{2581}vi", "\u{2581}ses", ".", "<blk>"]
    let words = TransducerText.words(
        [Token(id: 1, frame: 0, duration: 2), Token(id: 2, frame: 4, duration: 1),
         Token(id: 3, frame: 5, duration: 0), Token(id: 4, frame: 6, duration: 1),
         Token(id: 0, frame: 7, duration: 1),
         Token(id: 5, frame: 20, duration: 2), Token(id: 6, frame: 23, duration: 3),
         Token(id: 7, frame: 26, duration: 1)],
        vocabulary: vocab, offsetMs: 10_000)
    check("pieces join into words at the word marker",
          words.map(\.text) == ["hej", "då,", "vi", "ses."], "\(words.map(\.text))")
    check("a word starts on its first piece's frame, on the track's clock",
          words.first?.startMs == 10_000 && words[1].startMs == 10_320)
    check("a word ends where its last piece does, never before it starts",
          words[1].endMs == 10_560 && words.allSatisfy { $0.endMs > $0.startMs })
    check("control pieces carry no text", !words.contains { $0.text.contains("<") })
    check("a token outside the vocabulary is skipped, not a crash",
          TransducerText.words([Token(id: 99, frame: 0, duration: 1)],
                               vocabulary: vocab, offsetMs: 0).isEmpty)

    // MARK: Words → segments
    func w(_ text: String, _ start: Int, _ end: Int) -> TransducerText.Word {
        TransducerText.Word(text: text, startMs: start, endMs: end)
    }
    let sentences = TransducerText.segments(
        [w("Hej", 0, 300), w("då.", 350, 700), w("Vi", 800, 1000), w("ses", 1050, 1300)])
    check("a sentence end closes the segment",
          sentences.map(\.text) == ["Hej då.", "Vi ses"], "\(sentences.map(\.text))")
    check("a segment spans its own words, not the pause after them",
          sentences.first?.startMs == 0 && sentences.first?.endMs == 700)
    let paused = TransducerText.segments([w("ja", 0, 200), w("precis", 1_200, 1_600)])
    check("a real pause closes the segment without punctuation", paused.count == 2)
    let long = TransducerText.segments((0..<40).map { w("ord", $0 * 500, $0 * 500 + 400) })
    check("no segment outlasts the cap",
          long.count > 1 && long.allSatisfy { ($0.endMs ?? 0) - $0.startMs <= TransducerText.segmentMaxMs },
          "\(long.map { ($0.endMs ?? 0) - $0.startMs })")
    check("every word lands in exactly one segment",
          long.reduce(0) { $0 + TranscriptRouter.wordCount($1.text) } == 40)

    // MARK: Audio → pieces
    let joined = TransducerText.chunks([(0, 3_000), (3_400, 6_000), (9_000, 10_000)], voice: nil)
    check("spans a breath apart are decoded as one piece",
          joined.count == 2 && joined[0].startMs == 0 && joined[0].endMs == 6_000, "\(joined)")
    let capped = TransducerText.chunks([(0, 10_000), (10_200, 20_000)], voice: nil)
    check("joining stops at the piece cap", capped.count == 2, "\(capped)")
    // 40 s of speech with one quiet window at 13.0 s.
    var peaks = [Int](repeating: 2_000, count: 800)
    peaks[260] = 3
    let cut = TransducerText.chunks([(0, 40_000)],
                                    voice: WavLevel.Envelope(windowMs: 50, peaks: peaks))
    check("an over-long span is cut at its quietest point, not mid-word",
          cut.first?.endMs == 13_000, "\(cut)")
    check("cut pieces cover the span exactly once",
          cut.first?.startMs == 0 && cut.last?.endMs == 40_000
              && zip(cut, cut.dropFirst()).allSatisfy { $0.endMs == $1.startMs }
              && cut.allSatisfy { $0.endMs - $0.startMs <= TransducerText.chunkMaxMs })

    // MARK: Routing by text
    // A stand-in recognizer: text that contains "the" is English.
    let classify: (String) -> (language: String, confidence: Double)? = {
        ($0.lowercased().contains("the") ? "en" : "sv", 0.95)
    }
    func seg(_ start: Int, _ text: String, _ ms: Int = 2_000) -> Transcriber.Segment {
        Transcriber.Segment(startMs: start, text: text, endMs: start + ms)
    }
    func route(_ tracks: [[Transcriber.Segment]],
               evidence: [Transcriber.Segment] = []) -> [TranscriptRouter.Routed] {
        TranscriptRouter.route(tracks: tracks, evidence: evidence, home: "sv",
                               languages: ["sv", "en"], classify: classify)
    }
    let svLine = "det är verkligen inte så svårt"
    let enLine = "the thing about the product is clear"

    let swedish = route([[seg(0, svLine), seg(3_000, "Ja."), seg(5_000, "Mm."), seg(7_000, svLine)], []])
    check("a Swedish call keeps every line of the first decode",
          swedish[0].redo.isEmpty && swedish[0].kept.count == 4)

    let quoted = route([[seg(0, svLine), seg(3_000, "Let the tokens flow."), seg(6_000, svLine)], []])
    check("a short English phrase inside Swedish is not a switch",
          quoted[0].redo.isEmpty && quoted[0].kept.count == 3)

    let mixed = route([[seg(0, svLine), seg(60_000, enLine), seg(63_000, "Yeah."),
                        seg(65_000, enLine), seg(120_000, svLine)], []])
    check("an English passage is one stretch, backchannel included",
          mixed[0].redo.count == 1 && mixed[0].redo[0].language == "en"
              && mixed[0].kept.count == 2, "\(mixed[0].redo)")
    check("a stretch is padded but never into a line that keeps its text",
          mixed[0].redo[0].startMs == 59_800 && mixed[0].redo[0].endMs == 67_200,
          "\(mixed[0].redo[0].startMs)–\(mixed[0].redo[0].endMs)")

    // The 2026-11-10 13:00 call: the far end speaks English, and the Swedish
    // model wrote the user's short replies down in Swedish.
    let bent = route([[seg(10_000, "Tack så mycket."), seg(20_000, "Nej.")],
                      [seg(0, enLine), seg(8_000, enLine), seg(15_000, enLine)]])
    check("short replies take the language of the conversation on the other track",
          bent[0].kept.isEmpty && bent[0].redo.allSatisfy { $0.language == "en" }
              && bent[1].kept.isEmpty, "\(bent[0].kept.map(\.text))")

    let sampled = route([[seg(10_000, "Okej."), seg(20_000, "Precis.")], []],
                        evidence: [seg(0, enLine), seg(15_000, enLine)])
    check("a track that skipped its first decode still informs the other one",
          sampled[0].kept.isEmpty && sampled[0].redo.count == 1)

    let alone = route([[seg(0, "Ja."), seg(5_000, "Okej.")], []])
    check("with nothing to go on, a line stays in the model's own language",
          alone[0].redo.isEmpty && alone[0].kept.count == 2)

    let unsure = TranscriptRouter.route(
        tracks: [[seg(0, svLine), seg(3_000, enLine), seg(6_000, svLine)]], home: "sv",
        languages: ["sv", "en"],
        classify: { ($0.contains("the") ? "en" : "sv", $0.contains("the") ? 0.61 : 0.95) })
    check("an unsure reading is not evidence", unsure[0].redo.isEmpty)

    let offList = TranscriptRouter.route(
        tracks: [[seg(0, enLine), seg(3_000, enLine)]], home: "sv", languages: ["sv", "de"],
        classify: classify)
    check("a language the call is not set up for is never routed to", offList[0].redo.isEmpty)

    // MARK: Sampling a track
    let chunkList = (0..<40).map { (startMs: $0 * 10_000, endMs: $0 * 10_000 + ($0 % 2 == 0 ? 6_000 : 1_000)) }
    let picks = TranscriptRouter.probeIndices(chunkList)
    check("samples are spread across the track and skip scraps",
          picks.count == TranscriptRouter.probeCount && picks.allSatisfy { $0 % 2 == 0 }
              && picks.first! < 6 && picks.last! > 33, "\(picks)")
    func plan(_ samples: [String], home: String = "sv",
              installed: Set<String> = ["sv", "en"]) -> TranscriptRouter.Plan {
        TranscriptRouter.plan(samples, home: home, languages: ["sv", "en"],
                              installed: installed, classify: classify)
    }
    check("every sample English → the track skips the Swedish decode",
          plan(Array(repeating: enLine, count: 8)) == .whole("en"))
    check("a Swedish track is decoded by the Swedish model",
          plan(Array(repeating: svLine, count: 8)) == .decode("sv"))
    check("one stray English sample does not move a Swedish track",
          plan(Array(repeating: svLine, count: 7) + [enLine]) == .decode("sv"))
    check("too few usable samples decide nothing",
          plan(Array(repeating: enLine, count: 3) + ["Yeah.", "Okay."]) == .decode("sv"))
    // English dominant, a Swedish call with English terms in it.
    check("a track mostly in another language is decoded first by that language's model",
          plan(Array(repeating: svLine, count: 6) + [enLine, enLine], home: "en") == .decode("sv"))
    check("…but only when that language has a model of its own",
          plan(Array(repeating: svLine, count: 6) + [enLine, enLine], home: "en",
               installed: ["en"]) == .decode("en"))
    check("an even split stays with the home model",
          plan(Array(repeating: svLine, count: 4) + Array(repeating: enLine, count: 4), home: "en") == .decode("en"))

    // Each track read against its own model's language.
    let perTrack = TranscriptRouter.route(
        tracks: [[seg(0, svLine), seg(3_000, svLine)], [seg(1_000, enLine), seg(4_000, enLine)]],
        homes: ["sv", "en"], languages: ["sv", "en"], classify: classify)
    check("a track decoded by another model keeps what reads as that model's language",
          perTrack[0].redo.isEmpty && perTrack[1].redo.isEmpty
              && perTrack[0].kept.count == 2 && perTrack[1].kept.count == 2)
    let crossed = TranscriptRouter.route(
        tracks: [[seg(0, enLine), seg(3_000, enLine)]], homes: ["sv"],
        languages: ["sv", "en"], classify: classify)
    check("…and hands on what does not", crossed[0].kept.isEmpty && crossed[0].redo.first?.language == "en")

    // MARK: Hesitations
    let spoken = TransducerText.withoutHesitations(
        [w("Uh,", 0, 100), w("so", 200, 300), w("we", 400, 500), w("um", 600, 700),
         w("shipped", 800, 900), w("it,", 1_000, 1_100), w("uh.", 1_200, 1_300),
         w("Yeah.", 2_000, 2_100), w("Mm.", 3_000, 3_100), w("Umbrella", 4_000, 4_100)],
        language: "en")
    check("hesitation sounds are dropped from English",
          spoken.map(\.text) == ["So", "we", "shipped", "it.", "Yeah.", "Mm.", "Umbrella"],
          "\(spoken.map(\.text))")
    check("what remains keeps its own timing",
          spoken.first?.startMs == 200 && spoken[3].endMs == 1_100)
    check("a reply is not a hesitation",
          TransducerText.withoutHesitations([w("Mm.", 0, 100), w("Hmm.", 200, 300)], language: "en").count == 2)
    check("a language with no list is left exactly as decoded",
          TransducerText.withoutHesitations([w("Um", 0, 100), w("ja", 200, 300)], language: "sv").count == 2)

    // MARK: Catalog + install
    let dir = "/models/pianissimo-sv-onnx"
    func four(_ d: String) -> [String] {
        ["\(d)/nemo128.onnx", "\(d)/encoder-model.int8.onnx",
         "\(d)/decoder_joint-model.int8.onnx", "\(d)/vocab.txt"]
    }
    let all = Set(four(dir))
    check("four files make an installed model",
          TransducerModel.files(at: dir, present: all.contains) != nil)
    check("a folder missing its vocabulary is not a model",
          TransducerModel.files(at: dir, present: { all.subtracting(["\(dir)/vocab.txt"]).contains($0) }) == nil)

    check("Swedish and Danish are known models",
          TransducerCatalog.known.map(\.language) == ["sv", "da", "en"]
              && TransducerCatalog.known.allSatisfy(\.verified))
    let danish = TransducerCatalog.entry(for: "da")
    check("a known language resolves to its repo and folder",
          danish.repo == "KlangAI/pianissimo-da-onnx" && danish.directory == "pianissimo-da-onnx")
    let urls = TransducerCatalog.models(for: danish).map(\.url.absoluteString)
    check("its four downloads point at that repo",
          urls.count == 4 && urls.allSatisfy { $0.hasPrefix("https://huggingface.co/KlangAI/pianissimo-da-onnx/resolve/main/") }
              && TransducerCatalog.models(for: danish).allSatisfy { $0.filename.hasPrefix("pianissimo-da-onnx/") })
    let future = TransducerCatalog.entry(for: "NO")
    check("a language Ghostie has never seen follows Klang's naming, unverified",
          future.repo == "KlangAI/pianissimo-no-onnx" && future.directory == "pianissimo-no-onnx"
              && !future.verified && future.language == "no")
    check("an unverified model claims no file sizes, so nothing is skipped on a guess",
          TransducerCatalog.models(for: future).allSatisfy { $0.approxBytes == 0 })
    check("a folder's language comes from its name",
          TransducerCatalog.language(ofDirectory: "pianissimo-da-onnx") == "da"
              && TransducerCatalog.language(ofDirectory: "pianissimo-fi-onnx") == "fi"
              && TransducerCatalog.language(ofDirectory: "parakeet-v3-en-onnx") == "en")
    check("folders that are not models are not given a language",
          TransducerCatalog.language(ofDirectory: "onnxruntime-osx-arm64-1.29.0") == nil
              && TransducerCatalog.language(ofDirectory: "pianissimo-onnx") == nil
              && TransducerCatalog.language(ofDirectory: "ggml-base.en.bin") == nil)
    let disk = Set(four("/m/pianissimo-sv-onnx") + four("/m/pianissimo-no-onnx") + four("/m/custom-sv-onnx")
        + ["/m/pianissimo-da-onnx/vocab.txt"])
    let found = TransducerCatalog.installed(
        in: "/m",
        list: { _ in ["custom-sv-onnx", "pianissimo-no-onnx", "pianissimo-da-onnx", "pianissimo-sv-onnx", "ggml-base.en.bin"] },
        present: disk.contains)
    check("installed models are found on disk, future languages included",
          found["sv"] != nil && found["no"] == "/m/pianissimo-no-onnx", "\(found)")
    check("a half-downloaded model is not installed", found["da"] == nil)
    check("two models for one language: the known folder wins",
          found["sv"] == "/m/pianissimo-sv-onnx")
    check("the dominant language's model decodes first when it has one",
          TransducerCatalog.home(languages: ["en", "sv", "da"], dominant: "da",
                                 installed: ["sv": "a", "da": "b"]) == "da")
    check("otherwise the first of the call's languages with a model",
          TransducerCatalog.home(languages: ["en", "sv", "da"], dominant: "en",
                                 installed: ["sv": "a", "da": "b"]) == "sv")
    check("a model for a language the call is not set up for is never chosen",
          TransducerCatalog.home(languages: ["en", "de"], dominant: "en", installed: ["sv": "a"]) == nil)
    check("language codes are told from flags and variants",
          TransducerCatalog.isLanguageCode("da") && !TransducerCatalog.isLanguageCode("--transducer")
              && !TransducerCatalog.isLanguageCode("standard") && !TransducerCatalog.isLanguageCode("DA"))
    check("Norwegian is asked of the recognizer under the code it knows",
          TranscriptRouter.recognizerCode("no") == "nb" && TranscriptRouter.recognizerCode("da") == "da")
    let nordic = TranscriptRouter.language(of: "Jeg tror ikke at det er en god idé at vente til i morgen",
                                           among: ["sv", "da", "en"])
    check("the recognizer tells written Danish from Swedish", nordic?.language == "da", "\(String(describing: nordic))")
    let norsk = TranscriptRouter.language(of: "Jeg vet ikke hvorfor de ikke kunne komme hjem i går kveld",
                                          among: ["sv", "no"])
    check("…and answers in the call's own code", norsk?.language == "no", "\(String(describing: norsk))")

    check("Swedish beside Danish cannot be routed by text",
          TranscriptRouter.lookalikes(in: ["en", "sv", "da"]).map { [$0.0, $0.1] } == ["sv", "da"])
    check("Swedish beside English can",
          TranscriptRouter.lookalikes(in: ["en", "sv"]) == nil
              && TranscriptRouter.lookalikes(in: ["da", "en", "de", "fi"]) == nil)

    // MARK: Config
    check("the transducer path is off unless asked for", CodeSwitchConfig().transducerDecode == false)
    let old = try? JSONDecoder().decode(CodeSwitchConfig.self, from: Data(#"{"minSwitchMs":3000}"#.utf8))
    check("a config written before the key existed still decodes, with it off",
          old?.minSwitchMs == 3_000 && old?.transducerDecode == false)
    let on = try? JSONDecoder().decode(CodeSwitchConfig.self, from: Data(#"{"transducerDecode":true}"#.utf8))
    check("the key round-trips",
          on?.transducerDecode == true
              && (try? JSONEncoder().encode(on)).flatMap { String(data: $0, encoding: .utf8) }?
                  .contains("\"transducerDecode\":true") == true)

    // MARK: Download verification
    check("a git-stored file is verified by its git blob id",
          ModelDownloader.gitBlobID(Data()) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
              && ModelDownloader.gitBlobID(Data("hello\n".utf8)) == "ce013625030ba8dba906f756967f9e9ca394464a")
    check("a 64-character checksum is still compared as SHA256",
          ModelDownloader.matches(expected: String(repeating: "a", count: 64),
                                  sha256: String(repeating: "A", count: 64), file: "/nonexistent")
              && !ModelDownloader.matches(expected: String(repeating: "a", count: 64),
                                          sha256: String(repeating: "b", count: 64), file: "/nonexistent"))

    print("Transducer self-test: \(passed) passed, \(failed) failed")
    return failed == 0
}
