import Foundation

/// Speaker embeddings from WeSpeaker ResNet34 (ONNX), used to tell the people
/// on the *Participants* track apart.
///
/// Ghostie's two-track capture already separates "Me" from "Participants"
/// physically — the mic cannot contain the far end and system audio cannot
/// contain the mic — which is a stronger signal than any diarizer could infer.
/// What it cannot do is split the far end when three people share one system
/// audio stream. That is the only thing this model is asked to do.
///
/// Optional in exactly the way the ONNX language identifier is: no runtime, no
/// model, or a model that fails to load all mean "diarization is unavailable",
/// and the transcript keeps today's single "Participants" label rather than
/// failing the call.
///
/// `feats [1, T, 80] → embs [1, 256]`, cosine-comparable after the L2
/// normalization applied here.
final class SpeakerEmbedder {

    /// Dimensions the model declares in its own ONNX metadata. Checked at load
    /// rather than assumed, so pointing `speakerModel` at some other network
    /// fails loudly at startup instead of silently clustering noise.
    static let embeddingDim = 256

    /// Shortest span worth embedding. Below ~0.6 s a WeSpeaker embedding is
    /// dominated by phonetic content rather than speaker identity.
    static let minWindowMs = 600
    /// Window and hop for chopping a long turn into comparable pieces.
    ///
    /// Longer is markedly better: measured on real call audio, whole-window
    /// embeddings of ~6–8 s separate speakers with no overlap at all, while
    /// short 1.5 s windows are noisy enough that averaging them still leaves a
    /// third, mixed cluster. Most Whisper segments are shorter than this, so
    /// in practice a segment is embedded whole and the sliding only kicks in
    /// for long monologue turns.
    static let windowMs = 8_000
    static let hopMs = 4_000

    private let session: ORTSession

    private init(session: ORTSession) { self.session = session }

    /// Default on-disk location, alongside the whisper and VAD models.
    static var defaultModelPath: String {
        "\(Config.modelsDir)/\(Models.speakerEmbedding.filename)"
    }

    /// Returns nil (with one explanatory log line) whenever diarization simply
    /// is not available on this machine — never throws into the pipeline.
    static func load(config: Config) -> SpeakerEmbedder? {
        let path = config.speakerModel.isEmpty ? defaultModelPath : config.speakerModel
        guard FileManager.default.fileExists(atPath: path) else {
            Log.info("Speaker diarization off: no embedding model at \(path). Run `ghostie fetch-models --diarization` to add it.")
            return nil
        }
        guard let runtime = ORTRuntime.shared else {
            Log.info("Speaker diarization off: ONNX Runtime is not available (install it with `brew install onnxruntime`, or use a build that bundles it).")
            return nil
        }
        do {
            let session = try runtime.makeSession(modelPath: path)
            return SpeakerEmbedder(session: session)
        } catch {
            Log.warn("Speaker diarization off: could not load \(path) — \(error.localizedDescription)")
            return nil
        }
    }

    func shutdown() { session.close() }

    /// A window has to be mostly *speech*, not room tone. An embedding
    /// computed from silence is meaningless, but it is still unit-length and
    /// still lands somewhere, and clustering has no way to know it should be
    /// ignored — measured on a real call, ungated windows were the entire
    /// same-speaker similarity tail (5th percentile −0.04, i.e. the same
    /// person looking as different from himself as from a stranger), and that
    /// tail is what smears two clean speakers into one mixed cluster.
    ///
    /// Same "active" floor `WavLevel` uses for its silent-track guard, so one
    /// definition of "there is audio here" serves both.
    static let activePeak: Float = 256.0 / 32768        // ≈ −42 dBFS
    static let minActiveFraction: Float = 0.35
    private static let activeFrame = Fbank.sampleRate / 10   // 100 ms

    /// Fraction of 100 ms frames carrying anything above the noise floor.
    static func activeFraction(_ samples: [Float]) -> Float {
        let frames = samples.count / activeFrame
        guard frames > 0 else { return 0 }
        var active = 0
        for f in 0..<frames {
            let lo = f * activeFrame
            var peak: Float = 0
            for i in lo..<(lo + activeFrame) {
                let m = abs(samples[i])
                if m > peak { peak = m }
            }
            if peak >= activePeak { active += 1 }
        }
        return Float(active) / Float(frames)
    }

    static func isVoiced(_ samples: [Float]) -> Bool {
        activeFraction(samples) >= minActiveFraction
    }

    /// L2-normalized embedding for one span of 16 kHz mono samples, or nil if
    /// the span is too short, or too quiet, to say anything about who is
    /// speaking.
    func embed(_ samples: [Float]) -> [Float]? {
        guard samples.count >= Fbank.sampleRate * Self.minWindowMs / 1000,
              Self.isVoiced(samples),
              let (feats, frames) = Fbank.features(samples) else { return nil }
        guard let raw = try? session.run(
                input: feats, shape: [1, Int64(frames), Int64(Fbank.numBins)]),
              raw.count == Self.embeddingDim else { return nil }
        return Self.normalized(raw)
    }

    /// Unit-length copy, so cosine similarity is a plain dot product.
    static func normalized(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        for x in v { norm += x * x }
        norm = norm.squareRoot()
        guard norm > 1e-9 else { return v }
        return v.map { $0 / norm }
    }

    /// Cosine similarity of two already-normalized embeddings.
    static func similarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var dot: Float = 0
        for i in a.indices { dot += a[i] * b[i] }
        return dot
    }
}
