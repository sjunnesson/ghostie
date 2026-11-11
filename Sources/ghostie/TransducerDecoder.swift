import Foundation

/// A NeMo FastConformer-TDT speech model (NVIDIA Parakeet and its fine-tunes,
/// e.g. Klang Pianissimo for Swedish) running under the ONNX Runtime Ghostie
/// already loads for diarization. A second decoder beside whisper.cpp, used
/// per language where one is installed.
///
/// Why it exists: measured 2026-11-11 on a 30-minute Swedish call, the int8
/// Pianissimo export decoded a track in 57 s on CPU against 130–194 s for
/// KB-Whisper large, put 4 segments over near-silent audio against 22, and
/// spelled English terms inside Swedish sentences better. It is Swedish-only
/// (83% agreement with large-v3 on English, dropping content words), so it
/// replaces one language's decode and nothing else.
///
/// The export is three graphs plus a vocabulary, all in one directory:
/// `nemo128.onnx` (waveform → 128-band log-mel, so no DSP is ported here),
/// an encoder, and a joint decoder stepped once per emitted token.
final class TransducerModel {

    /// Encoder/decoder file names in preference order: the int8 export is
    /// what Ghostie downloads; a hand-installed fp32 one is honoured too.
    static let encoderNames = ["encoder-model.int8.onnx", "encoder-model.onnx"]
    static let decoderNames = ["decoder_joint-model.int8.onnx", "decoder_joint-model.onnx"]
    static let featuresName = "nemo128.onnx"
    static let vocabName = "vocab.txt"

    /// Encoder frame length: 10 ms features, subsampled 8×.
    static let frameMs = 80
    /// A stuck decoder must not loop on one frame forever.
    static let maxTokensPerFrame = 10

    enum ModelError: Error, LocalizedError {
        case missing(String)
        case malformed(String)
        var errorDescription: String? {
            switch self {
            case .missing(let what): return "speech model is incomplete: \(what)"
            case .malformed(let what): return "speech model is not the expected shape: \(what)"
            }
        }
    }

    /// The four files that make a usable model at `directory`, or nil.
    static func files(at directory: String,
                      present: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
        -> (features: String, encoder: String, decoder: String, vocab: String)? {
        func first(_ names: [String]) -> String? {
            names.map { "\(directory)/\($0)" }.first(where: present)
        }
        guard let encoder = first(encoderNames), let decoder = first(decoderNames),
              let features = first([featuresName]), let vocab = first([vocabName]) else { return nil }
        return (features, encoder, decoder, vocab)
    }

    struct Token: Equatable {
        let id: Int
        /// Encoder frame the token was emitted on.
        let frame: Int
        /// Frames the model said the token lasts (TDT's duration head).
        let duration: Int
    }

    let directory: String
    let vocabulary: [String]
    private let blank: Int
    private let features: ORTSession
    private let encoder: ORTSession
    private let decoder: ORTSession

    init(directory: String, runtime: ORTRuntime) throws {
        guard let files = Self.files(at: directory) else {
            throw ModelError.missing(directory)
        }
        self.directory = directory
        self.vocabulary = try Self.loadVocabulary(files.vocab)
        guard let blank = vocabulary.firstIndex(of: "<blk>"), blank == vocabulary.count - 1 else {
            throw ModelError.malformed("vocabulary does not end in <blk>")
        }
        self.blank = blank
        // The mel front end is tiny; the encoder is where the time goes, and
        // it scales with the performance cores.
        let cores = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        self.features = try runtime.makeSession(modelPath: files.features, threads: 2)
        self.encoder = try runtime.makeSession(modelPath: files.encoder, threads: cores)
        self.decoder = try runtime.makeSession(modelPath: files.decoder, threads: 2)
    }

    /// `vocab.txt`: one `<piece> <id>` per line, ids dense from 0.
    static func loadVocabulary(_ path: String) throws -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ModelError.missing(path)
        }
        var pieces: [Int: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let space = line.lastIndex(of: " "),
                  let id = Int(line[line.index(after: space)...]) else { continue }
            pieces[id] = String(line[..<space])
        }
        guard !pieces.isEmpty, pieces.count == (pieces.keys.max() ?? -1) + 1 else {
            throw ModelError.malformed("vocabulary ids are not dense")
        }
        return (0..<pieces.count).map { pieces[$0]! }
    }

    /// Greedy TDT decode of one stretch of 16 kHz mono audio in [-1, 1].
    func decode(samples: [Float]) throws -> [Token] {
        guard !samples.isEmpty else { return [] }
        // The encoder subsamples 8×; under about a quarter second there is
        // nothing left for it to stand on, so pad short scraps with silence.
        var wav = samples
        if wav.count < 8_000 { wav += [Float](repeating: 0, count: 8_000 - wav.count) }

        let mel = try features.run(
            inputs: [("waveforms", .float(wav, shape: [1, Int64(wav.count)])),
                     ("waveforms_lens", .int64([Int64(wav.count)], shape: [1]))],
            outputs: ["features", "features_lens"])
        guard mel.count == 2, mel[0].shape.count == 3, let melLen = mel[1].ints.first else {
            throw ModelError.malformed("feature extractor output")
        }
        let enc = try encoder.run(
            inputs: [("audio_signal", .float(mel[0].floats, shape: mel[0].shape.map(Int64.init))),
                     ("length", .int64([melLen], shape: [1]))],
            outputs: ["outputs", "encoded_lengths"])
        guard enc.count == 2, enc[0].shape.count == 3, let encLen = enc[1].ints.first else {
            throw ModelError.malformed("encoder output")
        }
        // [1, D, T], channel-major: frame t is every D-th value from t.
        let dim = enc[0].shape[1], total = enc[0].shape[2]
        let frames = min(Int(encLen), total)
        let encoded = enc[0].floats

        var tokens: [Token] = []
        var state1 = [Float](repeating: 0, count: 2 * 640)
        var state2 = [Float](repeating: 0, count: 2 * 640)
        var frame = [Float](repeating: 0, count: dim)
        var last = blank
        var t = 0, emitted = 0
        while t < frames {
            for c in 0..<dim { frame[c] = encoded[c * total + t] }
            let out = try decoder.run(
                inputs: [("encoder_outputs", .float(frame, shape: [1, Int64(dim), 1])),
                         ("targets", .int32([Int32(last)], shape: [1, 1])),
                         ("target_length", .int32([1], shape: [1])),
                         ("input_states_1", .float(state1, shape: [2, 1, 640])),
                         ("input_states_2", .float(state2, shape: [2, 1, 640]))],
                outputs: ["outputs", "output_states_1", "output_states_2"])
            guard out.count == 3, out[0].floats.count > vocabulary.count else {
                throw ModelError.malformed("decoder output")
            }
            let logits = out[0].floats
            let token = Self.argmax(logits, 0..<vocabulary.count)
            let step = Self.argmax(logits, vocabulary.count..<logits.count) - vocabulary.count
            if token != blank {
                tokens.append(Token(id: token, frame: t, duration: step))
                last = token
                state1 = out[1].floats
                state2 = out[2].floats
                emitted += 1
            }
            if step > 0 {
                t += step; emitted = 0
            } else if token == blank || emitted >= Self.maxTokensPerFrame {
                t += 1; emitted = 0
            }
        }
        return tokens
    }

    private static func argmax(_ values: [Float], _ range: Range<Int>) -> Int {
        var best = range.lowerBound
        for i in range where values[i] > values[best] { best = i }
        return best
    }

    func close() {
        features.close(); encoder.close(); decoder.close()
    }
}

/// Everything about a transducer's output that is not inference: tokens into
/// words, words into the segments the rest of the pipeline expects, and the
/// audio into pieces worth handing the model. Pure, so `selftest` covers it
/// without a model on disk.
enum TransducerText {

    struct Word: Equatable {
        var text: String
        let startMs: Int
        var endMs: Int
    }

    /// SentencePiece's word-start marker.
    static let wordStart: Character = "\u{2581}"

    /// Tokens → words on the original track's clock. A piece that starts
    /// with the marker opens a word; anything else (a suffix, a comma)
    /// continues the one before it. Control pieces (`<unk>`, `<|…|>`) carry
    /// no text.
    static func words(_ tokens: [TransducerModel.Token], vocabulary: [String],
                      offsetMs: Int, frameMs: Int = TransducerModel.frameMs) -> [Word] {
        var out: [Word] = []
        for token in tokens where vocabulary.indices.contains(token.id) {
            let piece = vocabulary[token.id]
            if piece.hasPrefix("<") && piece.hasSuffix(">") { continue }
            let start = offsetMs + token.frame * frameMs
            let end = offsetMs + (token.frame + max(1, token.duration)) * frameMs
            if piece.first == wordStart || out.isEmpty {
                let text = piece.first == wordStart ? String(piece.dropFirst()) : piece
                // A bare marker opens a word whose text arrives on the next piece.
                out.append(Word(text: text, startMs: start, endMs: end))
            } else {
                out[out.count - 1].text += piece
                out[out.count - 1].endMs = max(out[out.count - 1].endMs, end)
            }
        }
        return out.filter { !$0.text.isEmpty }
    }

    /// Hesitation sounds a model writes down that the transcript is better
    /// without, by the model's language. Parakeet is verbatim where whisper
    /// is not: on the 2026-09-11 reference call it wrote "uh" 198 times and
    /// "um" 118 times more than the reference holds, which was the whole of
    /// its deficit — 82.1% of its words matched against whisper's 86.9%, and
    /// 88.8% against 89.7% once those sounds were set aside on both sides.
    /// Only sounds that are never a word and never an answer: "mm", "hmm" and
    /// "yeah" are somebody replying, and stay.
    static let hesitations: [String: Set<String>] = ["en": ["uh", "um", "uhm", "erm"]]

    /// `words` without the hesitation sounds of `language`. What a dropped
    /// one carried is handed on: its sentence-ending mark to the word before,
    /// its capital to the word after.
    static func withoutHesitations(_ words: [Word], language: String) -> [Word] {
        guard let sounds = hesitations[language.lowercased()] else { return words }
        var out: [Word] = []
        var capitalizeNext = false
        for word in words {
            let bare = word.text.lowercased().filter { $0.isLetter }
            guard sounds.contains(bare) else {
                var kept = word
                if capitalizeNext, let first = kept.text.first, first.isLowercase {
                    kept.text = first.uppercased() + kept.text.dropFirst()
                }
                capitalizeNext = false
                out.append(kept)
                continue
            }
            if word.text.first?.isUppercase == true { capitalizeNext = true }
            if let mark = word.text.last, ".?!".contains(mark), let last = out.last?.text.last,
               !".?!".contains(last) {
                // "…the plan, um." → "…the plan."
                var text = out[out.count - 1].text
                if text.last == "," { text.removeLast() }
                out[out.count - 1].text = text + String(mark)
                capitalizeNext = true
            }
        }
        return out
    }

    /// A pause this long between two words ends the segment.
    static let segmentGapMs = 700
    /// No segment runs longer than this. Diarization embeds each segment's
    /// span as one voice, and the guard against text decoded from silence
    /// reads a long span as suspicious — both written for whisper, whose
    /// speech segments run a few seconds.
    static let segmentMaxMs = 12_000

    /// Words → segments: one per sentence, cut early at a real pause, never
    /// longer than `maxMs`. Each carries the span of its own words, so a
    /// segment's end is where its speaker stopped, not where the next began.
    static func segments(_ words: [Word], gapMs: Int = segmentGapMs,
                         maxMs: Int = segmentMaxMs) -> [Transcriber.Segment] {
        var out: [Transcriber.Segment] = []
        var current: [Word] = []
        func flush() {
            guard let first = current.first, let last = current.last else { return }
            out.append(Transcriber.Segment(
                startMs: first.startMs,
                text: current.map(\.text).joined(separator: " "),
                endMs: max(last.endMs, first.startMs)))
            current = []
        }
        for word in words {
            if let first = current.first, let last = current.last,
               word.startMs - last.endMs >= gapMs || word.endMs - first.startMs > maxMs {
                flush()
            }
            current.append(word)
            if let end = word.text.last, ".?!".contains(end) { flush() }
        }
        flush()
        return out
    }

    /// Longest stretch handed to the model at once. The model reads any
    /// length, but it was trained on clips, and measured on the 2026-11-11
    /// spike a whole track in two-minute pieces came back 8% shorter than the
    /// same audio cut at its pauses.
    static let chunkMaxMs = 15_000
    /// Speech spans closer together than this go to the model as one piece,
    /// pause included — a sentence should not lose its context to a breath.
    static let chunkJoinGapMs = 600

    /// Speech spans → the pieces to decode. Neighbouring spans are joined
    /// while the piece stays under `maxMs`; a single span longer than that is
    /// cut at the quietest point of its last third, so a cut lands in a pause
    /// rather than a word. Every piece is contiguous original audio, so a
    /// token's time is the piece's start plus its frame — no offset table.
    static func chunks(_ spans: [(startMs: Int, endMs: Int)],
                       voice: WavLevel.Envelope?,
                       maxMs: Int = chunkMaxMs,
                       joinGapMs: Int = chunkJoinGapMs) -> [(startMs: Int, endMs: Int)] {
        var joined: [(startMs: Int, endMs: Int)] = []
        for span in spans.sorted(by: { $0.startMs < $1.startMs }) where span.endMs > span.startMs {
            if let last = joined.last, span.startMs - last.endMs <= joinGapMs,
               span.endMs - last.startMs <= maxMs {
                joined[joined.count - 1].endMs = max(last.endMs, span.endMs)
            } else {
                joined.append(span)
            }
        }
        var out: [(startMs: Int, endMs: Int)] = []
        for var piece in joined {
            while piece.endMs - piece.startMs > maxMs {
                let cut = quietest(in: voice, fromMs: piece.startMs + maxMs * 2 / 3,
                                   toMs: piece.startMs + maxMs)
                out.append((piece.startMs, cut))
                piece.startMs = cut
            }
            out.append(piece)
        }
        return out
    }

    /// Start of the quietest envelope window in the range, or the range's end
    /// when there is no envelope to consult.
    private static func quietest(in voice: WavLevel.Envelope?, fromMs: Int, toMs: Int) -> Int {
        guard let voice, voice.windowMs > 0 else { return toMs }
        var best = toMs, bestPeak = Int.max
        var ms = (fromMs / voice.windowMs) * voice.windowMs
        while ms + voice.windowMs <= toMs {
            let peak = voice.peak(fromMs: ms, toMs: ms + voice.windowMs)
            if ms >= fromMs, peak < bestPeak { bestPeak = peak; best = ms }
            ms += voice.windowMs
        }
        return best
    }
}
