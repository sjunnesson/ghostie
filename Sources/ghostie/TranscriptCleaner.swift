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
        var afterKnownHallucinations = 0
        var afterDedup = 0
        var afterInterleaved = 0
        var afterNoiseMarkers = 0
        var afterTrailingTrim = 0
        var removed: Int { max(0, original - afterTrailingTrim) }
        var summary: String {
            "transcript guard: \(original) → \(afterTrailingTrim) segments (\(removed) hallucinated removed)"
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

    struct Seg { let startMs: Int; var text: String }

    /// Runs the guard pipeline (fixed order — it matters for correctness).
    static func clean(_ input: [(startMs: Int, text: String)])
        -> (segments: [Seg], stats: Stats) {
        var stats = Stats()
        stats.original = input.count
        var segs = input.map { Seg(startMs: $0.startMs, text: $0.text) }
            .filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }

        // 1. Drop training-data-leak hallucinations (YouTube/Amara/URLs).
        segs = segs.filter { !isKnownHallucination($0.text) }
        stats.afterKnownHallucinations = segs.count

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
                out.append(Seg(startMs: segs[i].startMs,
                               text: "[…] repeated audio removed — \(run) segments collapsed"))
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
