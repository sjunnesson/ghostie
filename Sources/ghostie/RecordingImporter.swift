import Foundation
import AVFoundation

/// Brings a recording made outside Ghostie — a voice memo, a phone
/// recording, an exported call — into the pipeline. Decodes whatever
/// AVFoundation can open (m4a, mp3, wav, aiff, caf, mp4/mov audio…), folds
/// it to 16 kHz mono PCM and lays it out as a session folder
/// (`<workDir>/<stamp>/participants.wav`) exactly as `AudioRecorder` would
/// have, so everything downstream — transcription, diarization, naming,
/// summary, backlog — runs unchanged.
///
/// The audio goes on the *Participants* track, never Me. An in-person
/// recording has everyone in one signal, and diarization only ever runs on
/// the Participants track, so this is the only placement that splits the
/// room into people. The user is one of them: "Participant N", not "Me".
/// `Pipeline.transcribeMerge` treats the absent `me.wav` as a silent track.
///
/// The session folder is named for when the recording was *made*, not
/// imported: the file's embedded creation date when it has one (Voice
/// Memos, phones and most recorders write it), else the filesystem creation
/// date, else now. The note is dated the same way.
enum RecordingImporter {
    struct Imported {
        let result: AudioRecorder.Result
        let startedAt: Date
        let sourceName: String
    }

    enum ImportError: LocalizedError {
        case unreadable(String, String)
        case empty(String)
        case cannotWrite(String)
        case conversion(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name, let why):
                return "\(name) could not be opened as audio (\(why))."
            case .empty(let name):
                return "\(name) contains no audio."
            case .cannotWrite(let path):
                return "Could not write \(path) — is the recordings folder writable?"
            case .conversion(let why):
                return "Audio conversion failed: \(why)"
            }
        }
    }

    static let targetRate: Double = 16_000

    /// Decode `source` into a fresh session folder under `config.workDir`.
    /// Synchronous and CPU-bound (a 1 h file takes a few seconds); callers
    /// run it on a work queue.
    static func importFile(_ source: URL, config: Config) throws -> Imported {
        let name = source.lastPathComponent
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: source)
        } catch {
            throw ImportError.unreadable(name, error.localizedDescription)
        }
        guard file.length > 0 else { throw ImportError.empty(name) }

        let inFormat = file.processingFormat   // Float32, deinterleaved
        let channels = Int(inFormat.channelCount)
        let startedAt = recordedAt(source)
        let dir = try makeSessionDir(config: config, startedAt: startedAt)
        let wavURL = dir.appendingPathComponent("participants.wav")
        guard let writer = WavWriter(url: wavURL, sampleRate: Int(targetRate)) else {
            throw ImportError.cannotWrite(wavURL.path)
        }

        // Fold channels ourselves and leave AVAudioConverter only the rate
        // change. `MicCapture` learned the hard way that a converter asked to
        // change channel count can fill its output with zeros and report
        // success; averaging is also the right fold here (a stereo memo is
        // the same room twice), unlike the voice-processed mic stream where
        // it would undo the echo cancellation.
        guard let monoIn = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: inFormat.sampleRate,
                                         channels: 1, interleaved: false),
              let outFormat = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                            sampleRate: targetRate,
                                            channels: 1, interleaved: true),
              let converter = AVAudioConverter(from: monoIn, to: outFormat)
        else {
            throw ImportError.conversion("no converter for \(inFormat)")
        }

        let chunk: AVAudioFrameCount = 65_536
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
              let monoBuf = AVAudioPCMBuffer(pcmFormat: monoIn, frameCapacity: chunk),
              let outBuf = AVAudioPCMBuffer(
                  pcmFormat: outFormat,
                  frameCapacity: AVAudioFrameCount(Double(chunk) * targetRate / inFormat.sampleRate) + 4096)
        else {
            throw ImportError.conversion("could not allocate buffers")
        }

        Log.info("Importing \(name): \(inFormat.sampleRate.formatted()) Hz, "
            + "\(channels) ch, \(String(format: "%.1f", Double(file.length) / inFormat.sampleRate / 60)) min "
            + "→ \(dir.lastPathComponent)/participants.wav")

        var reachedEnd = false
        while !reachedEnd {
            do {
                try file.read(into: inBuf, frameCount: chunk)
            } catch {
                throw ImportError.unreadable(name, error.localizedDescription)
            }
            reachedEnd = inBuf.frameLength < chunk
            if inBuf.frameLength == 0 && reachedEnd {
                // Flush whatever the resampler still holds.
                try drain(converter, into: outBuf, writer: writer, final: true)
                break
            }
            fold(inBuf, into: monoBuf, channels: channels)

            var fed = false
            var convError: NSError?
            let status = converter.convert(to: outBuf, error: &convError) { _, statusPtr in
                if fed {
                    statusPtr.pointee = reachedEnd ? .endOfStream : .noDataNow
                    return nil
                }
                fed = true
                statusPtr.pointee = .haveData
                return monoBuf
            }
            if status == .error {
                throw ImportError.conversion(convError?.localizedDescription ?? "unknown")
            }
            try append(outBuf, to: writer)
            if reachedEnd {
                try drain(converter, into: outBuf, writer: writer, final: true)
            }
        }

        let duration = writer.duration
        writer.close()
        guard duration > 0 else {
            try? FileManager.default.removeItem(at: dir)
            throw ImportError.empty(name)
        }
        Log.ok("Imported \(name) → \(String(format: "%.1f", duration / 60)) min at 16 kHz mono.")

        let result = AudioRecorder.Result(sessionDir: dir,
                                          micWav: dir.appendingPathComponent("me.wav"),
                                          systemWav: wavURL,
                                          duration: duration)
        return Imported(result: result, startedAt: startedAt, sourceName: name)
    }

    // MARK: - Pieces

    /// Average all input channels into `mono`.
    private static func fold(_ input: AVAudioPCMBuffer, into mono: AVAudioPCMBuffer,
                             channels: Int) {
        let frames = Int(input.frameLength)
        mono.frameLength = input.frameLength
        guard let src = input.floatChannelData, let dst = mono.floatChannelData?[0] else { return }
        if channels == 1 {
            dst.update(from: src[0], count: frames)
            return
        }
        let scale = 1 / Float(channels)
        for i in 0..<frames {
            var acc: Float = 0
            for c in 0..<channels { acc += src[c][i] }
            dst[i] = acc * scale
        }
    }

    /// Pull the converter's remaining output after the last input chunk.
    private static func drain(_ converter: AVAudioConverter, into out: AVAudioPCMBuffer,
                              writer: WavWriter, final: Bool) throws {
        var convError: NSError?
        let status = converter.convert(to: out, error: &convError) { _, statusPtr in
            statusPtr.pointee = .endOfStream
            return nil
        }
        if status == .error {
            throw ImportError.conversion(convError?.localizedDescription ?? "unknown")
        }
        try append(out, to: writer)
    }

    private static func append(_ out: AVAudioPCMBuffer, to writer: WavWriter) throws {
        let n = Int(out.frameLength)
        guard n > 0, let p = out.int16ChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: p, count: n))
        guard writer.append(samples) else { throw ImportError.cannotWrite(writer.url.path) }
    }

    /// `<workDir>/<yyyy-MM-dd_HH-mm-ss>`, suffixed `-2`, `-3`… if two imports
    /// land on the same second (or collide with a live session).
    private static func makeSessionDir(config: Config, startedAt: Date) throws -> URL {
        let base = URL(fileURLWithPath: config.workDir)
        let stamp = AudioRecorder.stampFormatter.string(from: startedAt)
        var dir = base.appendingPathComponent(stamp)
        var n = 1
        while FileManager.default.fileExists(atPath: dir.path) {
            n += 1
            dir = base.appendingPathComponent("\(stamp)-\(n)")
        }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            throw ImportError.cannotWrite(dir.path)
        }
        return dir
    }

    /// When the recording was made. The container's own creation date first
    /// (what Voice Memos, phones and most recorders stamp), then the file's
    /// creation date, then now.
    static func recordedAt(_ url: URL) -> Date {
        if let d = embeddedCreationDate(url) { return d }
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let d = attrs[.creationDate] as? Date { return d }
        return Date()
    }

    /// `AVAsset` metadata is async-only now; the importer runs on a work
    /// queue, so wait it out with a bounded semaphore rather than making the
    /// whole pipeline entry point async for one date.
    private static func embeddedCreationDate(_ url: URL) -> Date? {
        final class Box: @unchecked Sendable { var date: Date? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        let asset = AVURLAsset(url: url)
        Task.detached {
            defer { sem.signal() }
            guard let item = try? await asset.load(.creationDate) else { return }
            if let d = try? await item.load(.dateValue) {
                box.date = d
            } else if let s = try? await item.load(.stringValue) {
                box.date = ISO8601DateFormatter().date(from: s)
                    ?? ISO8601DateFormatter.withFractional.date(from: s)
            }
        }
        _ = sem.wait(timeout: .now() + 5)
        return box.date
    }
}

private extension ISO8601DateFormatter {
    static let withFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
