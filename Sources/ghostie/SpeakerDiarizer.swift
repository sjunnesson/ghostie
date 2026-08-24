import Foundation

/// Splits one track into individual speakers.
///
/// Only ever run on **Participants**. The "Me" track is the local microphone,
/// which by construction holds exactly one person, so diarizing it could only
/// invent speakers that are not there.
///
/// The shape of the problem here is unusually forgiving, and the design leans
/// on that: the segments come from Whisper, which has already cut the audio at
/// pauses, so this does not need to find speaker-change points in a continuous
/// stream — only to decide which of a handful of voices each existing segment
/// belongs to. Hence embed-then-cluster rather than a change-point detector.
///
/// 1. chop each segment into overlapping windows and embed them,
/// 2. average a segment's windows into one embedding,
/// 3. agglomerative clustering with average linkage on cosine distance,
/// 4. smooth away lone flips, which are nearly always a backchannel
///    ("mm", "ja") sitting inside someone else's turn.
struct SpeakerDiarizer {

    /// Cosine distance (`1 - similarity`) at which two clusters stop being the
    /// same person.
    ///
    /// Measured, not guessed. Over 222 voiced six-second windows drawn from
    /// two real recorded calls, same-speaker pairs ran mean +0.73 with a 1st
    /// percentile of +0.45, and different-speaker pairs mean −0.06 with a 95th
    /// percentile of +0.04 — separable with no overlap at all. Any cut between
    /// cosine 0.15 and 0.44 scores 100% on those pairs; 0.30 sits in the
    /// middle of that gap, so this is 1 − 0.30.
    ///
    /// The margin only exists because `SpeakerEmbedder` gates out unvoiced
    /// windows first. Without that gate the same-speaker 5th percentile is
    /// −0.04 and no threshold works.
    var mergeThreshold: Float = 0.70

    /// A track this short cannot support a reliable split.
    var minTrackSeconds: Double = 30
    /// Cap on how many people one far end is assumed to hold. Beyond this the
    /// clustering is almost certainly chasing noise, not speakers.
    var maxSpeakers = 8
    /// A cluster holding less than this share of embedded speech is folded
    /// into its nearest neighbour — real participants talk, and a sliver
    /// cluster is usually one noisy window, not a ninth person.
    var minClusterShare: Float = 0.03
    /// Give segments that could not be embedded their neighbour's speaker.
    /// The self-test and `diarize-probe` turn this off to measure clustering
    /// on its own, without gap-filling folded into the score.
    var fillUnlabelled = true

    struct Assignment {
        /// Speaker index per input segment, or nil where nothing could be
        /// embedded (too short, or silence Whisper hallucinated text onto).
        let speakers: [Int?]
        let speakerCount: Int
        var summary: String {
            let placed = speakers.compactMap { $0 }.count
            return speakerCount <= 1
                ? "diarization: one speaker on the Participants track"
                : "diarization: \(speakerCount) speakers on the Participants track (\(placed)/\(speakers.count) segments placed)"
        }
    }

    /// `segments` must be time-ordered; `samples` is the whole track as ±1
    /// mono 16 kHz floats. Returns nil when the track is too short, nothing
    /// could be embedded, or everything landed on one speaker — every one of
    /// which means "keep the existing single label".
    func diarize(segments: [Transcriber.Segment],
                 samples: [Float],
                 embedder: SpeakerEmbedder) -> Assignment? {
        let rate = Fbank.sampleRate
        guard Double(samples.count) / Double(rate) >= minTrackSeconds,
              segments.count > 1 else { return nil }

        // ---- 1 + 2: one embedding per segment, averaged over its windows.
        var embeddings: [[Float]?] = []
        var durations: [Float] = []
        for (i, seg) in segments.enumerated() {
            let endMs = seg.endMs ?? (i + 1 < segments.count
                                      ? segments[i + 1].startMs
                                      : seg.startMs + SpeakerEmbedder.windowMs)
            let (emb, seconds) = segmentEmbedding(
                startMs: seg.startMs, endMs: endMs,
                samples: samples, embedder: embedder)
            embeddings.append(emb)
            durations.append(seconds)
        }

        let indexed = embeddings.enumerated().compactMap { i, e in e.map { (i, $0) } }
        guard indexed.count >= 2 else { return nil }

        // ---- 3: agglomerative clustering.
        var clusters = agglomerate(indexed.map(\.1))
        clusters = foldTinyClusters(clusters,
                                    embeddings: indexed.map(\.1),
                                    weights: indexed.map { durations[$0.0] })

        var speakers = [Int?](repeating: nil, count: segments.count)
        for (n, (segmentIndex, _)) in indexed.enumerated() {
            speakers[segmentIndex] = clusters[n]
        }

        // ---- 4: smooth lone flips, then hand the unembeddable segments to
        // whoever is speaking around them. A segment too quiet to embed is
        // either a backchannel or a Whisper hallucination over silence;
        // either way its neighbours are a far better guess than "unknown",
        // which would surface as a bare label in the transcript.
        speakers = smoothed(speakers)
        if fillUnlabelled { speakers = fillGaps(speakers) }

        let ids = Set(speakers.compactMap { $0 })
        guard ids.count > 1 else { return nil }

        // Renumber so speaker 0 is whoever speaks first — "Participant 1"
        // should be the person who opened the call, not an arbitrary index.
        var order: [Int: Int] = [:]
        for s in speakers { if let s, order[s] == nil { order[s] = order.count } }
        speakers = speakers.map { $0.flatMap { order[$0] } }

        return Assignment(speakers: speakers, speakerCount: order.count)
    }

    /// 16-bit PCM bytes (as `AudioStitcher.readPCM` returns) → ±1 floats.
    static func floatSamples(_ pcm: Data) -> [Float] {
        let count = pcm.count / 2
        guard count > 0 else { return [] }
        var out = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            for i in 0..<count {
                out[i] = Float(raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self)) / 32768
            }
        }
        return out
    }

    // MARK: - Embedding

    /// Mean of the embeddings of a segment's overlapping windows, plus how
    /// many seconds of audio backed it. Averaging is what makes a segment's
    /// embedding robust to a single window that happened to catch a cough.
    private func segmentEmbedding(startMs: Int, endMs: Int,
                                  samples: [Float],
                                  embedder: SpeakerEmbedder) -> ([Float]?, Float) {
        let rate = Fbank.sampleRate
        let from = max(0, startMs * rate / 1000)
        let to = min(samples.count, max(from, endMs * rate / 1000))
        let span = to - from
        let minSamples = rate * SpeakerEmbedder.minWindowMs / 1000
        guard span >= minSamples else { return (nil, 0) }

        let window = rate * SpeakerEmbedder.windowMs / 1000
        let hop = rate * SpeakerEmbedder.hopMs / 1000
        var sum = [Float](repeating: 0, count: SpeakerEmbedder.embeddingDim)
        var used = 0
        var offset = from
        while offset + minSamples <= to {
            let end = min(to, offset + window)
            if let e = embedder.embed(Array(samples[offset..<end])) {
                for i in 0..<sum.count { sum[i] += e[i] }
                used += 1
            }
            if end == to { break }
            offset += hop
        }
        guard used > 0 else { return (nil, 0) }
        return (SpeakerEmbedder.normalized(sum), Float(span) / Float(rate))
    }

    // MARK: - Clustering

    /// Average-linkage agglomerative clustering on cosine distance, stopping
    /// once the closest pair is farther apart than `mergeThreshold`. Average
    /// linkage (not single) because single linkage chains two speakers
    /// together through one ambiguous segment.
    ///
    /// Internal for the self-test.
    func agglomerate(_ embeddings: [[Float]]) -> [Int] {
        let n = embeddings.count
        var cluster = Array(0..<n)
        var members: [Int: [Int]] = Dictionary(
            uniqueKeysWithValues: (0..<n).map { ($0, [$0]) })

        // Pairwise similarity, computed once.
        var sim = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in (i + 1)..<n {
                let s = SpeakerEmbedder.similarity(embeddings[i], embeddings[j])
                sim[i * n + j] = s
                sim[j * n + i] = s
            }
        }
        func linkage(_ a: [Int], _ b: [Int]) -> Float {
            var total: Float = 0
            for i in a { for j in b { total += sim[i * n + j] } }
            return total / Float(a.count * b.count)
        }

        while members.count > 1 {
            var best: (a: Int, b: Int, sim: Float)?
            let keys = members.keys.sorted()
            for (x, a) in keys.enumerated() {
                for b in keys[(x + 1)...] {
                    let s = linkage(members[a]!, members[b]!)
                    if best == nil || s > best!.sim { best = (a, b, s) }
                }
            }
            guard let best else { break }
            // Keep merging past the threshold while there are still more
            // clusters than a far end plausibly holds.
            let distance = 1 - best.sim
            if distance > mergeThreshold && members.count <= maxSpeakers { break }
            members[best.a]!.append(contentsOf: members[best.b]!)
            members[best.b] = nil
        }

        for (id, group) in members.enumerated().map({ ($0.offset, $0.element.value) }) {
            for m in group { cluster[m] = id }
        }
        return cluster
    }

    /// Folds clusters holding a negligible share of speech into their nearest
    /// surviving neighbour.
    private func foldTinyClusters(_ assignment: [Int],
                                  embeddings: [[Float]],
                                  weights: [Float]) -> [Int] {
        var mass: [Int: Float] = [:]
        for (i, c) in assignment.enumerated() { mass[c, default: 0] += weights[i] }
        let total = mass.values.reduce(0, +)
        guard total > 0, mass.count > 1 else { return assignment }

        let survivors = mass.filter { $0.value / total >= minClusterShare }.map(\.key)
        guard !survivors.isEmpty, survivors.count < mass.count else { return assignment }

        // Centroid per surviving cluster.
        var centroids: [Int: [Float]] = [:]
        for c in survivors {
            var sum = [Float](repeating: 0, count: SpeakerEmbedder.embeddingDim)
            for (i, a) in assignment.enumerated() where a == c {
                for k in 0..<sum.count { sum[k] += embeddings[i][k] }
            }
            centroids[c] = SpeakerEmbedder.normalized(sum)
        }
        return assignment.enumerated().map { i, c in
            guard centroids[c] == nil else { return c }
            return survivors.max {
                SpeakerEmbedder.similarity(embeddings[i], centroids[$0]!)
                    < SpeakerEmbedder.similarity(embeddings[i], centroids[$1]!)
            } ?? c
        }
    }

    /// Fills unlabelled segments from the labelled ones around them.
    ///
    /// A run of gaps bounded by the *same* speaker is that speaker still
    /// talking. A run bounded by two different speakers contains the handover,
    /// so it is split at its midpoint rather than handed wholesale to
    /// whichever side happens to come first — that one-sided version
    /// mislabelled 55 of 79 gaps on a two-speaker test track, this one
    /// roughly halves it. Gaps at the very start or end simply take the one
    /// neighbour they have.
    ///
    /// Internal for the self-test.
    func fillGaps(_ speakers: [Int?]) -> [Int?] {
        guard speakers.contains(where: { $0 == nil }),
              speakers.contains(where: { $0 != nil }) else { return speakers }
        var out = speakers
        var i = 0
        while i < out.count {
            guard out[i] == nil else { i += 1; continue }
            var j = i
            while j < out.count, out[j] == nil { j += 1 }
            let before = i > 0 ? out[i - 1] : nil
            let after = j < out.count ? out[j] : nil
            switch (before, after) {
            case let (b?, a?) where b == a:
                for k in i..<j { out[k] = b }
            case let (b?, a?):
                let mid = i + (j - i) / 2
                for k in i..<mid { out[k] = b }
                for k in mid..<j { out[k] = a }
            case let (b?, nil):
                for k in i..<j { out[k] = b }
            case let (nil, a?):
                for k in i..<j { out[k] = a }
            case (nil, nil):
                break
            }
            i = j
        }
        return out
    }

    /// A single segment attributed differently from both its neighbours, where
    /// those neighbours agree, is flipped to match them. That pattern is
    /// nearly always a short backchannel embedded in someone else's turn,
    /// where the embedding had almost no voiced audio to work with.
    ///
    /// Internal for the self-test.
    func smoothed(_ speakers: [Int?]) -> [Int?] {
        guard speakers.count > 2 else { return speakers }
        var out = speakers
        for i in 1..<(speakers.count - 1) {
            guard let prev = speakers[i - 1], let next = speakers[i + 1],
                  let cur = speakers[i], prev == next, cur != prev else { continue }
            out[i] = prev
        }
        return out
    }
}
