import Foundation
import NaturalLanguage

/// Language routing read off the transcript instead of the audio.
///
/// A transducer decodes whatever it is given in one pass, and — measured on
/// Klang Pianissimo — writes a spoken English sentence down as English even
/// inside a Swedish call. So "which stretches were in another language" can
/// be asked of the *text*, where it is easy, rather than of 1.5-second slices
/// of audio, where it cost 17.6 of a 30-minute call's 23 processing minutes
/// and still called "Ja. Mm. Gick det bra för henne den veckan eller?"
/// English.
///
/// Two rules carry it, both measured on real calls (2026-11-11):
///
/// **Only a full sentence is evidence.** On an all-English call the Swedish
/// model wrote "Thank you so much." as "Tack så mycket." and "No." as "Nej."
/// — a short utterance is bent toward the model's own language, and its text
/// then reads confidently as that language. Under `decidedWords` a sentence
/// says nothing about which language it was in.
///
/// **Everything else takes the language of the conversation around it**, on
/// either track: a "yeah" belongs to the exchange it was said in. That is the
/// same prior the acoustic smoother takes from the other track, applied to
/// words instead of posteriors.
enum TranscriptRouter {

    /// A sentence with fewer words than this is not evidence of a language.
    static let decidedWords = 5
    /// …and the recognizer must be this sure of the ones that are.
    static let minConfidence = 0.7
    /// How far either side an undecided sentence looks for its conversation.
    static let contextMs = 45_000
    /// Kept either side of a stretch handed to another decoder.
    static let paddingMs = 200

    struct Routed {
        /// Segments that keep the first decode's text.
        let kept: [Transcriber.Segment]
        /// Stretches to decode again with another language's model.
        let redo: [LanguageRun]
    }

    /// The language `text` is written in, among `languages`, with the
    /// recognizer's probability. nil when it has no opinion.
    static func language(of text: String, among languages: [String]) -> (language: String, confidence: Double)? {
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = languages.map { NLLanguage(rawValue: recognizerCode($0)) }
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first else { return nil }
        let code = languages.first { recognizerCode($0) == best.key.rawValue } ?? best.key.rawValue
        return (code, best.value)
    }

    /// Ghostie's (whisper's) language codes are not all the recognizer's:
    /// Norwegian is `no` here and `nb` there, and a constraint the recognizer
    /// does not know is silently no constraint at all.
    static func recognizerCode(_ code: String) -> String {
        switch code.lowercased() {
        case "no", "nn": return "nb"
        case "zh": return "zh-Hans"
        case "he", "iw": return "he"
        default: return code.lowercased()
        }
    }

    /// Languages close enough that one's model writes the other's speech
    /// down as its own. Text routing rests on a model leaving a foreign
    /// sentence recognisably foreign — true of Swedish against English, and
    /// measured false inside this group: the Swedish model turned Danish
    /// "Men det kedelige ved det var, at der sjældent eller aldrig…" into
    /// "Men det kedlige vid det var, att det kjällen eller aldrig…", which
    /// reads as Swedish, so three minutes of Danish stayed with the wrong
    /// model. Add a group here before trusting a new language beside a
    /// relative of it.
    static let lookalikeGroups: [Set<String>] = [["sv", "da", "no", "nb", "nn"]]

    /// Two of `languages` that text cannot tell apart after a first decode,
    /// or nil when routing by text is sound for this set.
    static func lookalikes(in languages: [String]) -> (String, String)? {
        for group in lookalikeGroups {
            let hit = languages.filter { group.contains($0.lowercased()) }
            if hit.count >= 2 { return (hit[0], hit[1]) }
        }
        return nil
    }

    static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " }).count
    }

    /// The language a sentence is evidence of, or nil when it is too short or
    /// too uncertain to count.
    static func decided(_ text: String, languages: [String],
                        classify: (String) -> (language: String, confidence: Double)?) -> String? {
        guard wordCount(text) >= decidedWords, let c = classify(text),
              c.confidence >= minConfidence, languages.contains(c.language) else { return nil }
        return c.language
    }

    /// Route every track of one call together. `tracks` are first decodes in
    /// `home`; `evidence` is extra decided-or-not text with timestamps that
    /// informs the conversation without being routed itself (the samples of a
    /// track that skipped its first decode). `classify` is injected so the
    /// selftest needs no recognizer.
    static func route(tracks: [[Transcriber.Segment]],
                      evidence: [Transcriber.Segment] = [],
                      home: String, languages: [String],
                      classify: (String) -> (language: String, confidence: Double)?) -> [Routed] {
        route(tracks: tracks, evidence: evidence, homes: tracks.map { _ in home },
              languages: languages, classify: classify)
    }

    /// As above, with each track decoded first by its own language's model
    /// (`homes[i]` for `tracks[i]`): a line keeps its text when it reads as
    /// the language of the model that wrote it.
    static func route(tracks: [[Transcriber.Segment]],
                      evidence: [Transcriber.Segment] = [],
                      homes: [String], languages: [String],
                      classify: (String) -> (language: String, confidence: Double)?) -> [Routed] {
        let fallback = homes.first ?? languages.first ?? ""
        func mid(_ s: Transcriber.Segment) -> Int { (s.startMs + (s.endMs ?? s.startMs)) / 2 }
        let own: [[String?]] = tracks.map { $0.map { decided($0.text, languages: languages, classify: classify) } }

        // Every decided sentence of the call, on one clock.
        var said: [(ms: Int, language: String, words: Int)] = []
        for (t, track) in tracks.enumerated() {
            for (i, s) in track.enumerated() {
                if let l = own[t][i] { said.append((mid(s), l, wordCount(s.text))) }
            }
        }
        for s in evidence {
            if let l = decided(s.text, languages: languages, classify: classify) {
                said.append((mid(s), l, wordCount(s.text)))
            }
        }
        said.sort { $0.ms < $1.ms }

        /// What the conversation around `ms` was in: the word-weighted
        /// majority within `contextMs`, else the nearest decided sentence
        /// anywhere, else `home`.
        func conversationAnywhere(at ms: Int) -> String {
            var votes: [String: Int] = [:]
            var nearest: (distance: Int, language: String)?
            for s in said {
                let distance = abs(s.ms - ms)
                if distance <= contextMs { votes[s.language, default: 0] += s.words }
                if nearest == nil || distance < nearest!.distance { nearest = (distance, s.language) }
            }
            if let top = votes.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
               votes.values.filter({ $0 == top.value }).count == 1 {
                return top.key
            }
            return nearest?.language ?? fallback
        }

        return tracks.enumerated().map { t, track in
            let home = homes[t]
            // With nothing said anywhere near, a line is its own model's.
            func conversation(at ms: Int) -> String { said.isEmpty ? home : conversationAnywhere(at: ms) }
            let labels = track.enumerated().map { i, s in own[t][i] ?? conversation(at: mid(s)) }
            var kept: [Transcriber.Segment] = []
            var redo: [LanguageRun] = []
            var i = 0
            while i < track.count {
                let lang = labels[i]
                guard lang != home else { kept.append(track[i]); i += 1; continue }
                var j = i
                while j + 1 < track.count, labels[j + 1] == lang { j += 1 }
                let startMs = track[i].startMs
                let endMs = track[j].endMs ?? track[j].startMs
                // Padded, but never into a neighbour that keeps its text.
                let floor = i > 0 ? (track[i - 1].endMs ?? track[i - 1].startMs) : 0
                let ceiling = j + 1 < track.count ? track[j + 1].startMs : Int.max
                let lo = max(0, min(startMs, max(floor, startMs - paddingMs)))
                redo.append(LanguageRun(language: lang, startMs: lo,
                                        endMs: max(lo + 1, max(endMs, min(ceiling, endMs + paddingMs))),
                                        segments: []))
                i = j + 1
            }
            return Routed(kept: kept, redo: redo)
        }
    }

    /// Samples to decode before committing a whole track to the first pass.
    static let probeCount = 10
    /// …of which at least this many must turn out to be evidence.
    static let probeMinDecided = 6

    /// Up to `count` of `chunks`, spread evenly, preferring none over short
    /// ones: a sample has to hold a full sentence to say anything.
    static func probeIndices(_ chunks: [(startMs: Int, endMs: Int)], count: Int = probeCount,
                             minMs: Int = 4_000) -> [Int] {
        let eligible = chunks.indices.filter { chunks[$0].endMs - chunks[$0].startMs >= minMs }
        guard eligible.count > count else { return eligible }
        return (0..<count).map { eligible[(2 * $0 + 1) * eligible.count / (2 * count)] }
    }

    /// Whether a track's samples, written by `language`'s model, are really
    /// in that language — asked of the recognizer with no shortlist.
    ///
    /// For the one-language install, where nothing else checks: "English" is
    /// often just what the installed whisper model is filed under, the
    /// language setting is "auto", and the person may be speaking German.
    /// Whisper would have followed them; a transducer writes what it can and
    /// the result reads as something else, or as nothing. Every sample that
    /// says anything must say `language`, and enough of them must speak.
    static func confirms(_ samples: [String], language: String,
                         classify: (String) -> (language: String, confidence: Double)?) -> Bool {
        let read = samples.filter { wordCount($0) >= decidedWords }.compactMap(classify)
            .filter { $0.confidence >= minConfidence }
        return read.count >= probeMinDecided
            && read.allSatisfy { recognizerCode($0.language) == recognizerCode(language) }
    }

    /// What to do with a track, decided from its samples.
    enum Plan: Equatable {
        /// Decode the whole track with this language's model, then route.
        case decode(String)
        /// Every sample was this one other language: no first decode, the
        /// whole track is that language's.
        case whole(String)
    }

    /// The plan for a track whose samples, decoded by `home`'s model, read as
    /// `samples`.
    ///
    /// Unanimously one other language → the whole track is that language's
    /// (unanimous-or-nothing, like the acoustic fast path: a wrong verdict
    /// sends a whole track to the wrong model, a missed one costs a minute).
    ///
    /// Mostly another language that has a transducer of its own → *that*
    /// model decodes the track first. The call's dominant language is a
    /// guess about the user, not about this recording: with English dominant
    /// and a Swedish call, the English model decoded all of it, the text
    /// said Swedish, and Pianissimo decoded it all again — 115 s against 54.
    static func plan(_ samples: [String], home: String, languages: [String],
                     installed: Set<String>,
                     classify: (String) -> (language: String, confidence: Double)?) -> Plan {
        let labels = samples.compactMap { decided($0, languages: languages, classify: classify) }
        guard labels.count >= probeMinDecided else { return .decode(home) }
        let counts = Dictionary(grouping: labels, by: { $0 }).mapValues(\.count)
        guard let top = counts.max(by: { ($0.value, $1.key) < ($1.value, $0.key) }),
              top.key != home else { return .decode(home) }
        if top.value == labels.count { return .whole(top.key) }
        if top.value * 2 > labels.count, installed.contains(top.key) { return .decode(top.key) }
        return .decode(home)
    }
}
