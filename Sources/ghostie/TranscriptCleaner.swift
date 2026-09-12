import Foundation

/// Post-transcription hallucination guard for whisper output.
///
/// Whisper is notorious for hallucinating on near-silent / noisy audio:
/// looping a phrase ("Thank you." ×30), emitting `[BLANK_AUDIO]` / `[music]`
/// runs, gluing on YouTube-subtitle training leaks ("Thanks for watching!",
/// "Subtitles by the Amara.org community", URLs). Decoder params alone don't
/// catch all of it. This is a Swift port of the language-agnostic, low-false-
/// positive guards from `whisper-guard` (the post-processing layer behind the
/// `minutes` project), with its production-tuned thresholds.
enum TranscriptCleaner {

    struct Stats {
        var original = 0
        var afterSilenceGate = 0
        var afterKnownHallucinations = 0
        var afterDedup = 0
        var afterInterleaved = 0
        var afterNoiseMarkers = 0
        var afterTrailingTrim = 0
        /// Segments dropped because their own span of the track was silent.
        var silenced = 0
        /// Set when the gate found so many silent segments that the
        /// timestamps, not the transcript, are the likelier fault — nothing
        /// is dropped in that case and the count is reported instead.
        var silenceGateStoodDown = 0
        var removed: Int { max(0, original - afterTrailingTrim) }
        var summary: String {
            var s = "transcript guard: \(original) → \(afterTrailingTrim) segments "
                + "(\(removed) hallucinated removed"
            if silenced > 0 { s += ", \(silenced) of them decoded from silence" }
            s += ")"
            if silenceGateStoodDown > 0 {
                s += " — silence gate stood down: \(silenceGateStoodDown) segments "
                    + "landed on silent audio, too many to be hallucinations"
            }
            return s
        }
    }

    // Non-speech event words whisper labels on near-silent / noisy audio
    // (English + the non-English tokens seen most in real captures).
    private static let noiseWords: Set<String> = [
        "crying", "laughter", "laughing", "applause", "growling", "music",
        "sobbing", "cheering", "sighing", "clapping", "coughing", "sneezing",
        "gasping", "whispering", "mumbling", "humming", "breathing", "silence",
        "snoring", "yelling", "screaming", "blank_audio", "inaudible", "noise",
        "crosstalk", "typing", "static", "beep", "ringing", "weeping",
        "śmiech", "risas", "musik", "musique", "musica", "música", "muzyka",
        "applaus", "aplausos", "applausi", "oklaski", "ruido", "geräusch",
        "stille", "silencio", "cisza", "rires", "rire", "gelächter"
    ]

    // Bracketed tokens that are NEVER legitimate content (trimmed at any count).
    private static func isAlwaysNoise(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        let s = t.hasSuffix(".") ? String(t.dropLast()) : t
        return ["[music]", "[blank_audio]", "[silence]", "music"].contains(s)
    }

    // Trailing fillers: only a 5+ run at the very end is trimmed (a single
    // "Yeah." / "Okay." is often a legitimate closing).
    private static let fillerWords: Set<String> = [
        "yeah", "okay", "ok", "you", "uh", "um", "hmm", "mm", "mhm", "so", "right"
    ]

    // English + the highest-frequency non-English YouTube-subtitle leaks.
    // Whisper's training-data hallucinations are language-specific: a Swedish
    // decode pass (code-switching) emits the Swedish leak phrases, which the
    // English-only list used to sail right past. Exact normalized phrases
    // only — nothing here can occur as legitimate business-call speech.
    private static let knownHallucinations: Set<String> = [
        "thank you for watching", "thanks for watching",
        "thank you so much for watching", "please subscribe to our channel",
        "please subscribe", "please like and subscribe", "like and subscribe",
        "smash that like button", "don't forget to subscribe",
        "see you in the next video", "see you next time",
        "subtitles by the amara.org community",
        "transcribed by the amara.org community",
        "translated by the amara.org community",
        "the amara.org community", "amara.org community",
        "captions by the cyclope",
        // Swedish
        "tack för att du tittade", "tack för att ni tittade",
        "tack för att du har tittat", "tack för visningen",
        "glöm inte att prenumerera", "prenumerera på kanalen",
        "vi ses i nästa video", "vi ses nästa gång",
        "undertexter från amara.org-gemenskapen",
        "svensktextning.nu",
        // German
        "vielen dank fürs zuschauen", "danke fürs zuschauen",
        "bis zum nächsten mal", "vergesst nicht zu abonnieren",
        "untertitel der amara.org-community",
        // French
        "merci d'avoir regardé", "merci d'avoir regardé cette vidéo",
        "abonnez-vous à la chaîne", "à la prochaine",
        "sous-titres réalisés para la communauté d'amara.org",
        "sous-titres réalisés par la communauté d'amara.org",
        // Spanish
        "gracias por ver", "gracias por ver el video",
        "gracias por ver el vídeo", "no olvides suscribirte",
        "suscríbete al canal",
        "subtítulos realizados por la comunidad de amara.org"
    ]
    private static let hallucinationPrefixes = [
        "transcripted by", "transcribed by", "captions by",
        "captioned by", "subtitles by", "translated by",
        // Swedish credit lines ("Textning av …", "Undertexter av/från …",
        // "Översättning: …" are subtitle credits, never call speech).
        "textning av", "undertexter av", "undertexter från",
        "översättning av", "översatt av",
        // German / French / Spanish credit lines
        "untertitel von", "untertitelung des",
        "sous-titres par", "sous-titrage par", "sous-titres réalisés",
        "subtítulos por", "subtítulos de", "subtitulado por"
    ]

    private static func normalized(_ text: String) -> String {
        text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?,;:"))
            .trimmingCharacters(in: .whitespaces)
    }

    private static func isURLLine(_ text: String) -> Bool {
        guard let first = text.trimmingCharacters(in: .whitespaces)
            .split(separator: " ").first.map(String.init) else { return false }
        return first.hasPrefix("www.") || first.hasPrefix("http://")
            || first.hasPrefix("https://")
    }

    private static func isKnownHallucination(_ text: String) -> Bool {
        let n = normalized(text)
        if n.isEmpty { return false }
        if knownHallucinations.contains(n) { return true }
        if hallucinationPrefixes.contains(where: { n.hasPrefix($0) }) { return true }
        return isURLLine(n)
    }

    /// Bracketed/parenthetical non-speech marker: 1–4 inner words, ≤40 chars,
    /// last inner word a known noise token (so "(music director)" survives).
    static func isNoiseMarker(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty || t.hasPrefix("[...]") { return false }
        if t.hasSuffix(".") { t = String(t.dropLast()) }
        let bracketed = (t.hasPrefix("[") && t.hasSuffix("]"))
            || (t.hasPrefix("(") && t.hasSuffix(")"))
        guard bracketed, t.count >= 2 else { return false }
        let inner = String(t.dropFirst().dropLast())
        if inner.allSatisfy({ $0.isNumber || $0 == ":" }) { return false }
        let words = inner.split(separator: " ").map(String.init)
        guard (1...4).contains(words.count), inner.count <= 40 else { return false }
        return words.last.map { noiseWords.contains($0.lowercased()) } ?? false
    }

    /// Whether `segment` was decoded from a span of `audio` that carried
    /// nothing. Requires a real end timestamp and a span the recording
    /// actually covers: "past the end of the WAV" is missing evidence, not
    /// silence, and must never read as one.
    static func isSilent(_ segment: Transcriber.Segment,
                         in audio: WavLevel.Envelope,
                         floor: Double = silenceFloor) -> Bool {
        guard let endMs = segment.endMs, endMs > segment.startMs,
              audio.covers(fromMs: segment.startMs, toMs: endMs) else { return false }
        return audio.activeFraction(fromMs: segment.startMs, toMs: endMs) <= floor
    }

    /// Whether `segment` is a few words stretched over a long, mostly quiet
    /// span — the shape of a hallucination that `isSilent` cannot see.
    ///
    /// `isSilent` asks for *nothing* in the span, which is the rule that needs
    /// no threshold defended. It catches a hallucination written onto digital
    /// silence, which is what Google Meet sends while the far side is quiet.
    /// A microphone track never goes digitally silent: it carries breath,
    /// keyboard, a chair, the room. On the 2026-09-11 Zoom call the Me track's
    /// quiet stretches still crossed `WavLevel.activeThreshold` in 5–13% of
    /// their windows, so six invented "Thank you." turns walked through a gate
    /// that had just dropped seven others.
    ///
    /// What separates them is the span. Whisper closes a segment every few
    /// seconds while someone is talking; it only hands out a long one when it
    /// has nothing to cut on, so a hallucination gets the whole quiet stretch
    /// (on the 2026-09-08 call, exactly 30.00 s every time). Real speech over
    /// a span that long is dense by construction.
    ///
    /// Measured over 184 whisper segments decoded from twelve two-minute
    /// slices of that call's Me track, scored against the audio: the nine
    /// segments at or past `stretchedSpanMs` with an active share at or below
    /// `stretchedFloor` are hallucinations without exception — three bare
    /// "Thank you."s, a bare "yeah", two loops repeating a real sentence onto
    /// silence, and three invented sentences. The real segments that long run
    /// 0.18 to 0.87 active. The two populations are 0.13 against 0.18 with
    /// nothing in between, and this threshold sits in that gap.
    ///
    /// It is a narrower gap than the diarizer's, which is why the rule needs
    /// *both* halves: fifteen seconds of near-silence is not an opinion about
    /// the text, and no segment shorter than `stretchedSpanMs` is ever judged
    /// by it.
    static func isStretchedOverQuiet(_ segment: Transcriber.Segment,
                                     in audio: WavLevel.Envelope,
                                     spanMs: Int = stretchedSpanMs,
                                     floor: Double = stretchedFloor) -> Bool {
        guard let endMs = segment.endMs, endMs - segment.startMs >= spanMs,
              audio.covers(fromMs: segment.startMs, toMs: endMs) else { return false }
        return audio.activeFraction(fromMs: segment.startMs, toMs: endMs) <= floor
    }

    /// Shortest span the stretched-over-quiet rule will judge. Fifteen
    /// seconds is far past where whisper cuts running speech, and every real
    /// segment that long in the measurement was dense.
    static let stretchedSpanMs = 15_000

    /// …and the active share below which such a span is quiet. See
    /// `isStretchedOverQuiet` for the measurement this sits in the middle of.
    static let stretchedFloor = 0.15

    /// Normalized longest-common-substring ratio (fast similarity measure),
    /// matching whisper-guard's consecutive-dedup heuristic.
    private static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a.lowercased()), y = Array(b.lowercased())
        if x.isEmpty || y.isEmpty { return x.isEmpty && y.isEmpty ? 1 : 0 }
        var prev = [Int](repeating: 0, count: y.count + 1)
        var best = 0
        for i in 1...x.count {
            var cur = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i-1] == y[j-1] {
                cur[j] = prev[j-1] + 1
                best = max(best, cur[j])
            }
            prev = cur
        }
        return Double(best) / Double(max(x.count, y.count))
    }

    /// A cleaned segment. `endMs` is **whisper's own** segment end, carried
    /// through every stage rather than recomputed.
    ///
    /// It used to stop here, and `Pipeline` rebuilt each span as "up to the
    /// next segment's start" before diarizing — which is the one thing
    /// `Transcriber.Segment.endMs` documents you must not do: that span
    /// swallows the pause between two segments, and the pause is exactly
    /// where a speaker change lives. Every embedding then carried the leading
    /// edge of whoever spoke next, which is a good way to make two people
    /// look like one.
    struct Seg { let startMs: Int; var text: String; var endMs: Int? = nil }

    /// A segment has to have *some* audible fraction of its own span to count
    /// as speech that happened. Zero means not one window of it — at 50 ms
    /// resolution, against `WavLevel.activeThreshold` (≈ −42 dBFS) — carried
    /// anything, over a span whisper itself chose.
    ///
    /// A share, not a peak, because whisper does not give a hallucination a
    /// short span. Measured by decoding 20 slices of the 2026-09-08 call and
    /// scoring every segment against a reference recording: each invented
    /// "Thank you." came back with an exactly 30.00-second span, one of which
    /// contained a lone sample of 91, so a peak test caught none of them. On
    /// those 172 segments this rule drops 4 of the 87 with no counterpart in
    /// the reference — all four the 30-second "Thank you." spans — and 1 of
    /// the 85 that have one, an "um". Allowing 1% active instead of 0 doubles
    /// the catch and still costs only that one, but zero is the rule that can
    /// be stated without a threshold anyone has to defend: nothing was there.
    static let silenceFloor = 0.0

    /// Above this share of gateable segments, the gate refuses to fire. A
    /// third of a call cannot be hallucinated onto silence; a timestamp base
    /// that disagrees with the audio (a stitched decode mapped back wrongly,
    /// a truncated WAV) looks exactly like this and would otherwise delete a
    /// real transcript quietly, which is the one outcome worth engineering
    /// against.
    static let maxSilentFraction = 0.35

    /// …but a share is only evidence of a systematic mismatch once there are
    /// enough segments for it to mean anything. Below this, a run of silent
    /// segments is just a quiet recording with a few invented lines in it —
    /// which is exactly what the gate is for — and refusing to fire would
    /// make the guard useless on every short call.
    static let minSegmentsToJudgeSilentFraction = 20

    /// Runs the guard pipeline (fixed order — it matters for correctness).
    static func clean(_ input: [(startMs: Int, text: String)])
        -> (segments: [Seg], stats: Stats) {
        clean(input.map { Transcriber.Segment(startMs: $0.startMs, text: $0.text) })
    }

    /// As above, with the track's audio available: segments whose own span of
    /// the recording carried nothing are dropped before any text-level rule
    /// runs. Whisper decodes silence as readily as speech and writes
    /// plausible sentences onto it; no amount of reading the text can tell
    /// those from the real thing, and the audio can.
    static func clean(_ input: [Transcriber.Segment],
                      audio: WavLevel.Envelope? = nil)
        -> (segments: [Seg], stats: Stats) {
        var stats = Stats()
        stats.original = input.count
        var spans = input.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

        // 0. Drop what was decoded from silence.
        if let audio {
            // By index, not by timestamp: two segments can legitimately share
            // a start, and only the one that is actually silent may go.
            let gateable = spans.indices.filter { spans[$0].endMs != nil }
            // Both audio rules feed one set, so the stand-down below covers
            // them together: a timestamp base that disagrees with the audio
            // makes every segment look quiet, by either rule.
            let silent = Set(gateable.filter {
                isSilent(spans[$0], in: audio)
                    || isStretchedOverQuiet(spans[$0], in: audio)
            })
            if gateable.count >= minSegmentsToJudgeSilentFraction,
               Double(silent.count) / Double(gateable.count) > maxSilentFraction {
                stats.silenceGateStoodDown = silent.count
            } else if !silent.isEmpty {
                spans = spans.indices.filter { !silent.contains($0) }.map { spans[$0] }
                stats.silenced = silent.count
            }
        }
        var segs = spans.map { Seg(startMs: $0.startMs, text: $0.text, endMs: $0.endMs) }
        stats.afterSilenceGate = segs.count

        // 1. Drop training-data-leak hallucinations (YouTube/Amara/URLs).
        segs = segs.filter { !isKnownHallucination($0.text) }
        stats.afterKnownHallucinations = segs.count

        // 1.5. Collapse loops *inside* a single segment ("Yeah, yeah, ×14" —
        // whisper loops within a segment as well as across them, and the
        // consecutive-dedup below only sees whole segments).
        segs = segs.map { Seg(startMs: $0.startMs,
                              text: collapseWithinSegmentLoop($0.text),
                              endMs: $0.endMs) }

        // 2. Collapse consecutive near-duplicate runs (≥3, similarity ≥0.8).
        segs = collapseConsecutive(segs)
        stats.afterDedup = segs.count

        // 3. Collapse an interleaved phrase that dominates a 10-line window.
        segs = collapseInterleaved(segs)
        stats.afterInterleaved = segs.count

        // 4. Collapse noise-marker runs / strip if they dominate.
        segs = collapseNoiseMarkers(segs)
        stats.afterNoiseMarkers = segs.count

        // 5. Trim trailing noise/filler tail.
        segs = trimTrailingNoise(segs)
        stats.afterTrailingTrim = segs.count
        return (segs, stats)
    }

    /// Collapses a 1–3-word phrase repeated ≥4× back-to-back inside one
    /// segment to a single occurrence ("Yeah, yeah, yeah, ×14" → "Yeah.").
    /// The ≥4 floor keeps genuine emphasis ("no, no, no") intact. Internal
    /// (not private) for the selftest.
    static func collapseWithinSegmentLoop(_ text: String) -> String {
        var tokens = text.split(separator: " ", omittingEmptySubsequences: true)
            .map(String.init)
        guard tokens.count >= 4 else { return text }
        var collapsed = false
        for phraseLen in 1...3 {
            var out: [String] = []
            var i = 0
            while i < tokens.count {
                guard i + phraseLen * 2 <= tokens.count else {
                    out.append(tokens[i]); i += 1; continue
                }
                let phrase = tokens[i..<i+phraseLen].map(normalized)
                guard !phrase.contains("") else {
                    out.append(tokens[i]); i += 1; continue
                }
                var reps = 1
                while i + (reps + 1) * phraseLen <= tokens.count,
                      tokens[(i + reps * phraseLen)..<(i + (reps + 1) * phraseLen)]
                          .map(normalized) == phrase {
                    reps += 1
                }
                if reps >= 4 {
                    collapsed = true
                    out.append(contentsOf: tokens[i..<i+phraseLen])
                    i += reps * phraseLen
                } else {
                    out.append(tokens[i]); i += 1
                }
            }
            tokens = out
        }
        guard collapsed else { return text }
        var result = tokens.joined(separator: " ")
        // A collapsed run usually ends mid-list ("Yeah,") — close it cleanly.
        if result.hasSuffix(",") { result = String(result.dropLast()) + "." }
        return result
    }

    private static func collapseConsecutive(_ segs: [Seg]) -> [Seg] {
        guard segs.count >= 3 else { return segs }
        var out: [Seg] = []
        var i = 0
        while i < segs.count {
            if isAlwaysNoise(segs[i].text) || isNoiseMarker(segs[i].text) {
                out.append(segs[i]); i += 1; continue
            }
            var run = 1
            while i + run < segs.count,
                  similarity(segs[i].text, segs[i+run].text) >= 0.8 { run += 1 }
            out.append(segs[i])
            if run >= 3 {
                // The marker stands for the whole collapsed run, so it spans
                // it: the last segment's end, not the first one's.
                out.append(Seg(startMs: segs[i].startMs,
                               text: "[…] repeated audio removed — \(run) segments collapsed",
                               endMs: segs[i + run - 1].endMs ?? segs[i].endMs))
            } else if run > 1 {
                for k in 1..<run { out.append(segs[i+k]) }
            }
            i += run
        }
        return out
    }

    private static func collapseInterleaved(_ segs: [Seg]) -> [Seg] {
        let window = 10
        guard segs.count >= window else { return segs }
        func norm(_ s: String) -> String { normalized(s) }
        var drop = Set<Int>()
        var i = 0
        while i + window <= segs.count {
            var freq: [String: Int] = [:]
            for j in i..<i+window {
                let n = norm(segs[j].text)
                if n.isEmpty || fillerWords.contains(n) { continue }
                freq[n, default: 0] += 1
            }
            if let (phrase, count) = freq.max(by: { $0.value < $1.value }),
               count >= 5, Double(count) >= Double(window) * 0.5 {
                var end = i + window
                while end < segs.count && norm(segs[end].text) == phrase { end += 1 }
                var kept = false
                for j in i..<end where norm(segs[j].text) == phrase {
                    if kept { drop.insert(j) } else { kept = true }
                }
                i = end
            } else { i += 1 }
        }
        return segs.enumerated().filter { !drop.contains($0.offset) }.map { $0.element }
    }

    private static func collapseNoiseMarkers(_ segs: [Seg]) -> [Seg] {
        guard segs.count >= 3 else { return segs }
        var out: [Seg] = []
        var i = 0
        while i < segs.count {
            if isNoiseMarker(segs[i].text) || isAlwaysNoise(segs[i].text) {
                var run = 1
                while i + run < segs.count,
                      isNoiseMarker(segs[i+run].text) || isAlwaysNoise(segs[i+run].text) {
                    run += 1
                }
                if run >= 3 { /* drop the whole run */ }
                else { for k in 0..<run { out.append(segs[i+k]) } }
                i += run
            } else { out.append(segs[i]); i += 1 }
        }
        // If noise markers still dominate (≥66% and ≥8), strip them all.
        let markers = out.filter { isNoiseMarker($0.text) || isAlwaysNoise($0.text) }.count
        if !out.isEmpty, markers >= 8,
           Double(markers) / Double(out.count) >= 0.66 {
            out = out.filter { !(isNoiseMarker($0.text) || isAlwaysNoise($0.text)) }
        }
        return out
    }

    private static func trimTrailingNoise(_ segs: [Seg]) -> [Seg] {
        var end = segs.count
        // Bracketed/always-noise: trim at any count from the tail.
        while end > 0,
              isNoiseMarker(segs[end-1].text) || isAlwaysNoise(segs[end-1].text) {
            end -= 1
        }
        // Filler words: only a 5+ contiguous trailing run is trimmed.
        var fillerRun = 0
        var k = end
        while k > 0, fillerWords.contains(normalized(segs[k-1].text)) {
            fillerRun += 1; k -= 1
        }
        if fillerRun >= 5 { end = k }
        return Array(segs.prefix(end))
    }
}
