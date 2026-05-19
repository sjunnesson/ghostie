import Foundation

// MARK: - Shared code-switching data types
//
// These are deliberately whisper-free so the smoother (the algorithmically
// interesting, false-positive-prone part) is unit-testable from `ghostie
// selftest` with synthetic detections and no audio or model on disk.

/// A speech region found by VAD, in milliseconds from the start of the track.
struct VADSegment: Equatable {
    let startMs: Int
    let endMs: Int
    var durationMs: Int { max(0, endMs - startMs) }
}

/// The language guess for one VAD segment plus enough uncertainty information
/// for the Bayesian refinement pass. `logprobs` is whitelist-restricted
/// (sv/en); `top` is `"unknown"` when the segment was too short / too noisy
/// for a reliable call (see `CodeSwitchConfig.minDetectMs`).
struct LanguageDetection {
    let segment: VADSegment
    var top: String
    var confidence: Double          // softmax prob of `top` (0…1)
    var margin: Double              // top1 − top2 in log-space
    var logprobs: [String: Double]  // per-language log-prob (sv/en)

    static let unknown = "unknown"

    func relabel(top: String, confidence: Double) -> LanguageDetection {
        LanguageDetection(segment: segment, top: top, confidence: confidence,
                          margin: margin, logprobs: logprobs)
    }
}

/// Per-track preliminary language timeline: contiguous same-language intervals
/// covering the speech portions of one track.
struct LanguageTimeline {
    struct Interval {
        let startMs: Int
        let endMs: Int
        let language: String
        let confidence: Double
    }
    let intervals: [Interval]

    /// Language of the most recent confident interval that *ended at or before*
    /// `tMs` and within `withinMs` of it — past-only, so a colleague answering
    /// in English can't retro-push your Swedish question toward English.
    func mostRecentEndingBefore(_ tMs: Int, withinMs: Int) -> String? {
        var best: Interval?
        for iv in intervals where iv.endMs <= tMs {
            if best == nil || iv.endMs > best!.endMs { best = iv }
        }
        guard let b = best, tMs - b.endMs <= withinMs else { return nil }
        return b.language
    }
}

/// A maximal run of one language, ready to be stitched and decoded by that
/// language's model.
struct LanguageRun {
    let language: String
    let startMs: Int
    let endMs: Int
    let segments: [VADSegment]
}

/// Two-pass smoother. Pass 1 produces a stable per-track timeline; Pass 2
/// refines one track using the *other track's Pass-1 timeline* as a Bayesian
/// prior (read from preliminary, never refined, so there is no feedback loop).
struct Smoother {
    let languages: [String]            // whitelist, exactly 2 (e.g. ["sv","en"])
    let window: Int                    // sliding-median width
    let minSwitchSegments: Int         // hysteresis: consecutive to switch
    let minSwitchMs: Int               // …or this much opposite-language time
    let maxFillGapMs: Int              // unknown-fill reach
    let dominantLanguage: String       // base-rate tiebreaker
    let crossTrackPriorStrength: Double // 0.5 (off) … 1.0 (absolute)
    let priorLookbackMs: Int
    let runPaddingMs: Int

    init(config: CodeSwitchConfig, window: Int) {
        self.languages = config.languages.count >= 2
            ? Array(config.languages.prefix(2))
            : ["sv", "en"]
        self.window = max(1, window)
        self.minSwitchSegments = max(1, config.minSwitchSegments)
        self.minSwitchMs = max(1, config.minSwitchMs)
        self.maxFillGapMs = config.maxFillGapMs
        self.dominantLanguage = config.dominantLanguage
        self.crossTrackPriorStrength = min(1.0, max(0.5, config.crossTrackPriorStrength))
        self.priorLookbackMs = config.priorLookbackMs
        self.runPaddingMs = config.runPaddingMs
    }

    private var other: (String) -> String {
        { [languages] lang in languages.first { $0 != lang } ?? lang }
    }

    // MARK: Pass 1 — per-track preliminary

    /// Filled + median + hysteresis label sequence shared by both passes.
    private func preliminaryLabels(_ dets: [LanguageDetection]) -> [String] {
        hysteresis(median(filledLabels(dets)), dets.map { $0.segment.durationMs })
    }

    func preliminary(_ dets: [LanguageDetection]) -> LanguageTimeline {
        timeline(from: dets, labels: preliminaryLabels(dets))
    }

    // MARK: Pass 2 — cross-track Bayesian refinement → runs

    /// Per-segment refined label *before* median/hysteresis collapse — the
    /// raw Bayesian decision. Used by `refine` and by `ghostie selftest` to
    /// assert the cross-track contract at segment granularity (a lone 2 s
    /// switch is intentionally smoothed away in the final runs).
    func refinedSegmentLabels(_ dets: [LanguageDetection],
                              priorFrom otherTrack: LanguageTimeline) -> [String] {
        guard !dets.isEmpty else { return [] }
        let prelim = preliminaryLabels(dets)
        return dets.enumerated().map { (i, det) in
            let likelihood: [String: Double]
            if languages.contains(det.top), det.confidence > 0 {
                likelihood = self.likelihood(det)
            } else if languages.contains(prelim[i]) {
                likelihood = [prelim[i]: 0.6, other(prelim[i]): 0.4]
            } else {
                likelihood = self.likelihood(det)
            }
            let prior: [String: Double]
            if let recent = otherTrack.mostRecentEndingBefore(
                det.segment.startMs, withinMs: priorLookbackMs) {
                prior = [recent: crossTrackPriorStrength,
                         other(recent): 1 - crossTrackPriorStrength]
            } else {
                prior = [dominantLanguage: 0.55, other(dominantLanguage): 0.45]
            }
            let post = normalize(multiply(likelihood, prior))
            return post.max { $0.value < $1.value }!.key
        }
    }

    func refine(_ dets: [LanguageDetection],
                priorFrom otherTrack: LanguageTimeline) -> [LanguageRun] {
        guard !dets.isEmpty else { return [] }
        let segLabels = refinedSegmentLabels(dets, priorFrom: otherTrack)
        let relabeled = zip(dets, segLabels).map { $0.relabel(top: $1, confidence: $0.confidence) }
        let durs = dets.map { $0.segment.durationMs }
        return runs(from: relabeled, labels: hysteresis(median(segLabels), durs))
    }

    // MARK: Likelihood / prior math

    /// Softmax over the whitelist log-probs. Missing/sub-threshold detections
    /// (top == unknown) yield a near-uniform likelihood so the prior dominates.
    private func likelihood(_ det: LanguageDetection) -> [String: Double] {
        var lp: [String: Double] = [:]
        for l in languages { if let v = det.logprobs[l] { lp[l] = v } }
        if lp.count < 2 || det.top == LanguageDetection.unknown {
            // Derive a soft distribution from confidence around `top`; if even
            // that is unknown, fall back to uniform.
            if languages.contains(det.top), det.confidence > 0 {
                let c = min(0.99, max(0.5, det.confidence))
                return [det.top: c, other(det.top): 1 - c]
            }
            return Dictionary(uniqueKeysWithValues: languages.map { ($0, 1.0 / Double(languages.count)) })
        }
        let maxLp = lp.values.max() ?? 0
        var exp: [String: Double] = [:]
        for (k, v) in lp { exp[k] = Foundation.exp(v - maxLp) }
        return normalize(exp)
    }

    private func multiply(_ a: [String: Double], _ b: [String: Double]) -> [String: Double] {
        var out: [String: Double] = [:]
        for l in languages { out[l] = (a[l] ?? 0) * (b[l] ?? 0) }
        return out
    }

    private func normalize(_ d: [String: Double]) -> [String: Double] {
        let sum = d.values.reduce(0, +)
        guard sum > 0 else {
            return Dictionary(uniqueKeysWithValues: languages.map { ($0, 1.0 / Double(languages.count)) })
        }
        return d.mapValues { $0 / sum }
    }

    // MARK: Label-sequence smoothing

    /// Replace `unknown` with the nearer confident neighbour within
    /// `maxFillGapMs`; otherwise leave it `unknown` for the median to absorb.
    private func filledLabels(_ dets: [LanguageDetection]) -> [String] {
        let raw = dets.map { languages.contains($0.top) ? $0.top : LanguageDetection.unknown }
        var out = raw
        for i in raw.indices where raw[i] == LanguageDetection.unknown {
            var prevIdx: Int?, nextIdx: Int?
            var j = i - 1
            while j >= 0 { if raw[j] != LanguageDetection.unknown { prevIdx = j; break }; j -= 1 }
            j = i + 1
            while j < raw.count { if raw[j] != LanguageDetection.unknown { nextIdx = j; break }; j += 1 }
            let prevGap = prevIdx.map { dets[i].segment.startMs - dets[$0].segment.endMs }
            let nextGap = nextIdx.map { dets[$0].segment.startMs - dets[i].segment.endMs }
            let prevOK = prevGap.map { $0 <= maxFillGapMs } ?? false
            let nextOK = nextGap.map { $0 <= maxFillGapMs } ?? false
            if prevOK && nextOK {
                out[i] = (prevGap! <= nextGap!) ? raw[prevIdx!] : raw[nextIdx!]
            } else if prevOK {
                out[i] = raw[prevIdx!]
            } else if nextOK {
                out[i] = raw[nextIdx!]
            }
        }
        return out
    }

    /// Sliding majority ("median" for categorical labels) over `window`,
    /// centered. Ties and all-unknown windows keep the original label.
    private func median(_ labels: [String]) -> [String] {
        guard labels.count > 1, window > 1 else { return labels }
        let half = window / 2
        var out = labels
        for i in labels.indices {
            let lo = max(0, i - half), hi = min(labels.count - 1, i + half)
            var freq: [String: Int] = [:]
            for k in lo...hi where labels[k] != LanguageDetection.unknown {
                freq[labels[k], default: 0] += 1
            }
            guard let top = freq.max(by: { $0.value < $1.value }) else { continue }
            // Only override on a strict majority winner (no tie).
            let tied = freq.filter { $0.value == top.value }.count > 1
            out[i] = tied ? labels[i] : top.key
        }
        return out
    }

    /// Switch the timeline only when the opposite-language run spans
    /// `minSwitchSegments` segments OR `minSwitchMs` of audio; otherwise it's a
    /// brief loanword and keeps the current language. The duration arm makes
    /// this robust to coarse VAD (one long segment is still a real switch).
    private func hysteresis(_ labels: [String], _ durations: [Int]) -> [String] {
        guard let first = labels.first(where: { languages.contains($0) }) else { return labels }
        var out = labels
        var current = first
        var i = 0
        while i < out.count {
            let l = out[i]
            if !languages.contains(l) { out[i] = current; i += 1; continue }
            if l == current { i += 1; continue }
            var run = 1
            while i + run < out.count && out[i + run] == l { run += 1 }
            let spanMs = (i..<(i + run)).reduce(0) { $0 + durations[$1] }
            if run >= minSwitchSegments || spanMs >= minSwitchMs {
                current = l
                i += run
            } else {
                for k in i..<(i + run) { out[k] = current }
                i += run
            }
        }
        return out
    }

    // MARK: Assembly

    private func timeline(from dets: [LanguageDetection],
                          labels: [String]) -> LanguageTimeline {
        var ivs: [LanguageTimeline.Interval] = []
        var i = 0
        while i < dets.count {
            let lang = labels[i]
            var j = i
            var confSum = dets[i].confidence
            while j + 1 < dets.count && labels[j + 1] == lang {
                j += 1; confSum += dets[j].confidence
            }
            ivs.append(.init(startMs: dets[i].segment.startMs,
                             endMs: dets[j].segment.endMs,
                             language: lang,
                             confidence: confSum / Double(j - i + 1)))
            i = j + 1
        }
        return LanguageTimeline(intervals: ivs)
    }

    private func runs(from dets: [LanguageDetection],
                      labels: [String]) -> [LanguageRun] {
        var out: [LanguageRun] = []
        var i = 0
        while i < dets.count {
            let lang = labels[i]
            var j = i
            while j + 1 < dets.count && labels[j + 1] == lang { j += 1 }
            let segs = (i...j).map { dets[$0].segment }
            out.append(LanguageRun(
                language: lang,
                startMs: max(0, segs.first!.startMs - runPaddingMs),
                endMs: segs.last!.endMs + runPaddingMs,
                segments: segs))
            i = j + 1
        }
        return out
    }
}
