import Foundation
import CONNXRuntime

/// Minimal ONNX Runtime binding for the VoxLingua107 LID: dlopen the
/// onnxruntime dylib if one is installed, create one CPU inference session,
/// and run `[1, N] Float32 waveform → [1, C] Float32 logits`.
///
/// Deliberately NOT a SwiftPM binary dependency: linking Microsoft's ORT
/// xcframework would add hundreds of MB to every build and the notarized
/// `.dmg` for a feature most installs don't use. Instead the vendored C API
/// *declarations* (Sources/CONNXRuntime, MIT) give Swift the OrtApi
/// function-pointer table, and the only symbol resolved at runtime is
/// `OrtGetApiBase`. No runtime on the machine → `available()` is nil → the
/// segmenter keeps using the whisper LID exactly as before.
///
/// Thread-safety: an `ORTSession` is confined to the code-switching detect
/// pass, which is sequential (`LanguageSegmenter` runs on the pipeline's
/// serial work queue); ORT sessions themselves are internally thread-safe
/// for `Run`.
final class ORTRuntime {

    /// Where to look for the dylib, in order: explicit override, Homebrew
    /// (Apple Silicon + Intel), a copy bundled into Ghostie.app/Frameworks.
    static func dylibCandidates() -> [String] {
        var paths: [String] = []
        if let env = ProcessInfo.processInfo.environment["GHOSTIE_ORT_DYLIB"],
           !env.isEmpty {
            paths.append(env)
        }
        if let bundled = Bundle.main.privateFrameworksPath {
            paths.append("\(bundled)/libonnxruntime.dylib")
        }
        paths.append("/opt/homebrew/lib/libonnxruntime.dylib")
        paths.append("/usr/local/lib/libonnxruntime.dylib")
        return paths
    }

    /// The process-wide runtime (dlopen + OrtEnv are process-level; ORT logs
    /// a warning if you create more than one env). nil when no dylib is
    /// installed or the ABI handshake fails — callers treat that as "the
    /// ONNX LID is not available on this machine".
    static let shared: ORTRuntime? = resolution.runtime

    /// A dylib that was on disk and could not be used, with the reason.
    struct LoadFailure: Error {
        let path: String
        let reason: String
    }

    /// Every candidate that existed and was refused, in lookup order. Empty
    /// when one loaded, or when none was installed at all.
    static var refused: [LoadFailure] { resolution.refused }

    private static let resolution: (runtime: ORTRuntime?, refused: [LoadFailure]) = {
        var refused: [LoadFailure] = []
        for path in dylibCandidates() where FileManager.default.fileExists(atPath: path) {
            do {
                return (try ORTRuntime(dylibPath: path), refused)
            } catch let failure as LoadFailure {
                refused.append(failure)
            } catch {
                refused.append(LoadFailure(path: path, reason: error.localizedDescription))
            }
        }
        return (nil, refused)
    }()

    /// What every "diarization is off" message says about the runtime.
    static var unavailableReason: String { unavailableReason(refused: refused) }

    /// "Not installed" and "installed but refused" need opposite advice, and
    /// telling them apart is the point. A signed Ghostie runs under the
    /// hardened runtime, whose library validation refuses a dylib signed by
    /// another team — Homebrew's copy is ad-hoc signed — so on a build
    /// without its own copy, `brew install onnxruntime` is advice that
    /// cannot work. The 2026-09-29 call lost speaker separation that way, on
    /// a Mac where Homebrew's runtime was installed all along.
    static func unavailableReason(refused: [LoadFailure]) -> String {
        guard let first = refused.first else {
            return "ONNX Runtime not found — install it with `brew install onnxruntime`, or use a build that bundles it"
        }
        if first.reason.contains("different Team IDs")
            || first.reason.contains("not valid for use in process") {
            return "macOS refused the ONNX Runtime at \(first.path) — a signed Ghostie can only load the copy bundled inside the app, so reinstall Ghostie from a release build"
        }
        return "the ONNX Runtime at \(first.path) could not be loaded: \(first.reason)"
    }

    let dylibPath: String
    private let api: UnsafePointer<OrtApi>
    private var env: OpaquePointer?

    private init(dylibPath: String) throws {
        func refuse(_ reason: String) -> LoadFailure {
            LoadFailure(path: dylibPath, reason: reason)
        }
        guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL) else {
            throw refuse(dlerror().map { String(cString: $0) } ?? "dlopen failed")
        }
        typealias GetApiBaseFn = @convention(c) () -> UnsafePointer<OrtApiBase>?
        guard let sym = dlsym(handle, "OrtGetApiBase") else {
            throw refuse("no OrtGetApiBase symbol — not an ONNX Runtime library")
        }
        let getBase = unsafeBitCast(sym, to: GetApiBaseFn.self)
        guard let base = getBase() else { throw refuse("OrtGetApiBase returned nothing") }
        // Ask for the exact API version the vendored header was compiled
        // against; ORT guarantees returned tables for version V match V's
        // struct layout. An older installed runtime returns NULL — walk down
        // a few versions (we only touch members stable since API v1, and
        // OrtApi is append-only, so any table ≥ our floor is layout-safe).
        var table: UnsafePointer<OrtApi>?
        var version = UInt32(ORT_API_VERSION)
        while table == nil && version >= 17 {
            table = base.pointee.GetApi(version)
            if table == nil { version -= 1 }
        }
        guard let api = table else {
            throw refuse("API version \(ORT_API_VERSION) and every fallback down to 17 were refused — the runtime is too old")
        }
        self.dylibPath = dylibPath
        self.api = api
        var env: OpaquePointer?
        guard check(api, api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "ghostie", &env)),
              env != nil else { throw refuse("CreateEnv failed") }
        self.env = env
    }

    deinit {
        if let env { api.pointee.ReleaseEnv(env) }
    }

    /// `threads` is the intra-op pool: 2 suits the small per-window models
    /// (language ID, speaker embeddings); a speech encoder wants the
    /// performance cores.
    func makeSession(modelPath: String, threads: Int32 = 2) throws -> ORTSession {
        try ORTSession(api: api, env: env, modelPath: modelPath, threads: threads)
    }
}

/// One loaded model. Created per call (the code-switch pass), reused across
/// every segment of both tracks, released in `shutdown()`.
final class ORTSession {
    private let api: UnsafePointer<OrtApi>
    private var session: OpaquePointer?
    private var memoryInfo: OpaquePointer?
    let inputName: String
    let outputName: String

    enum ORTError: Error, LocalizedError {
        case failed(String)
        var errorDescription: String? {
            if case .failed(let m) = self { return "ONNX Runtime: \(m)" }
            return nil
        }
    }

    init(api: UnsafePointer<OrtApi>, env: OpaquePointer?, modelPath: String,
         threads: Int32 = 2) throws {
        self.api = api

        var options: OpaquePointer?
        guard check(api, api.pointee.CreateSessionOptions(&options)) else {
            throw ORTError.failed("CreateSessionOptions failed")
        }
        defer { api.pointee.ReleaseSessionOptions(options) }
        _ = check(api, api.pointee.SetIntraOpNumThreads(options, max(1, threads)))

        var session: OpaquePointer?
        let ok = modelPath.withCString { cPath in
            check(api, api.pointee.CreateSession(env, cPath, options, &session))
        }
        guard ok, session != nil else {
            throw ORTError.failed("could not load model at \(modelPath)")
        }
        self.session = session

        var memInfo: OpaquePointer?
        guard check(api, api.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memInfo)) else {
            api.pointee.ReleaseSession(session)
            self.session = nil
            throw ORTError.failed("CreateCpuMemoryInfo failed")
        }
        self.memoryInfo = memInfo

        // Read the model's actual input/output names rather than assuming
        // what the export script used.
        var allocator: UnsafeMutablePointer<OrtAllocator>?
        _ = check(api, api.pointee.GetAllocatorWithDefaultOptions(&allocator))
        func name(_ get: (OpaquePointer?, Int, UnsafeMutablePointer<OrtAllocator>?, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> OrtStatusPtr?) -> String {
            var raw: UnsafeMutablePointer<CChar>? = nil
            guard check(api, get(session, 0, allocator, &raw)), let raw else { return "" }
            let s = String(cString: raw)
            _ = api.pointee.AllocatorFree(allocator, raw)
            return s
        }
        self.inputName = name { s, i, a, out in api.pointee.SessionGetInputName(s, i, a, out) }
        self.outputName = name { s, i, a, out in api.pointee.SessionGetOutputName(s, i, a, out) }
    }

    /// Run `[1, wav.count] Float32 → [1, C] Float32` and return the C logits.
    /// Used by the language identifier, whose export carries its own feature
    /// pipeline in-graph and so takes raw waveform.
    func run(wav: [Float]) throws -> [Float] {
        try run(input: wav, shape: [1, Int64(wav.count)])
    }

    /// Run an arbitrarily shaped Float32 input and return the flattened
    /// output. The speaker embedder needs this: WeSpeaker takes precomputed
    /// `[1, T, 80]` filterbank features rather than a waveform.
    func run(input data: [Float], shape dims: [Int64]) throws -> [Float] {
        guard !data.isEmpty else { throw ORTError.failed("empty input") }
        guard dims.reduce(1, *) == Int64(data.count) else {
            throw ORTError.failed(
                "shape \(dims) does not describe \(data.count) values")
        }
        // ORT wraps the caller's buffer without copying it, so the tensor is
        // only valid while that buffer is borrowed: create it, run it and
        // copy the output out all inside the one borrow. (It used to escape
        // `withUnsafeMutableBytes`, which also copied the whole input.)
        return try data.withUnsafeBufferPointer { buf in
            try run(tensorData: UnsafeMutableRawPointer(mutating: buf.baseAddress!),
                    byteCount: buf.count * MemoryLayout<Float>.stride, shape: dims)
        }
    }

    /// `data` must stay valid for the whole call — ORT reads it during `Run`.
    /// It is never written: inputs are read-only to the session.
    private func run(tensorData: UnsafeMutableRawPointer, byteCount: Int,
                     shape dims: [Int64]) throws -> [Float] {
        var input: OpaquePointer?
        var shape = dims
        let created = shape.withUnsafeMutableBufferPointer { dims in
            check(api, api.pointee.CreateTensorWithDataAsOrtValue(
                memoryInfo, tensorData, byteCount,
                dims.baseAddress, dims.count,
                ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input))
        }
        guard created, input != nil else { throw ORTError.failed("could not create input tensor") }
        defer { api.pointee.ReleaseValue(input) }

        var output: OpaquePointer?
        var inName: UnsafePointer<CChar>? = nil
        var outName: UnsafePointer<CChar>? = nil
        let ran = inputName.withCString { inC in
            outputName.withCString { outC -> Bool in
                inName = inC; outName = outC
                var inputs: [OpaquePointer?] = [input]
                return withUnsafePointer(to: &inName) { inNames in
                    withUnsafePointer(to: &outName) { outNames in
                        inputs.withUnsafeMutableBufferPointer { vals in
                            check(api, api.pointee.Run(
                                session, nil,
                                inNames, vals.baseAddress, 1,
                                outNames, 1, &output))
                        }
                    }
                }
            }
        }
        guard ran, let output else { throw ORTError.failed("Run failed") }
        defer { api.pointee.ReleaseValue(output) }

        // Element count from the output's shape info.
        var info: OpaquePointer?
        guard check(api, api.pointee.GetTensorTypeAndShape(output, &info)) else {
            throw ORTError.failed("GetTensorTypeAndShape failed")
        }
        defer { api.pointee.ReleaseTensorTypeAndShapeInfo(info) }
        var count = 0
        guard check(api, api.pointee.GetTensorShapeElementCount(info, &count)), count > 0 else {
            throw ORTError.failed("empty output tensor")
        }
        var raw: UnsafeMutableRawPointer?
        guard check(api, api.pointee.GetTensorMutableData(output, &raw)), let raw else {
            throw ORTError.failed("GetTensorMutableData failed")
        }
        let logits = raw.bindMemory(to: Float.self, capacity: count)
        return Array(UnsafeBufferPointer(start: logits, count: count))
    }

    // MARK: Named, typed, many-in / many-out

    /// One input tensor for `run(inputs:outputs:)`.
    enum Input {
        case float([Float], shape: [Int64])
        case int64([Int64], shape: [Int64])
        case int32([Int32], shape: [Int64])
    }

    /// One output tensor: its shape, and its values as whichever of the two
    /// families the model produced.
    struct Output {
        let shape: [Int]
        var floats: [Float] = []
        var ints: [Int64] = []
    }

    /// Run a model with several named inputs and outputs — what a transducer
    /// needs (features + lengths in, logits + two recurrent states out) and
    /// the single-tensor `run(input:shape:)` cannot express.
    func run(inputs: [(name: String, value: Input)], outputs names: [String]) throws -> [Output] {
        var values: [OpaquePointer?] = []
        defer { for v in values { api.pointee.ReleaseValue(v) } }
        // ORT wraps the buffers without copying, so they must outlive `Run`:
        // each is copied once into storage this call owns.
        var storage: [UnsafeMutableRawPointer] = []
        defer { for p in storage { p.deallocate() } }

        func tensor<T>(_ data: [T], _ dims: [Int64], _ type: ONNXTensorElementDataType) throws {
            guard dims.reduce(1, *) == Int64(data.count) else {
                throw ORTError.failed("shape \(dims) does not describe \(data.count) values")
            }
            let bytes = max(1, data.count) * MemoryLayout<T>.stride
            let raw = UnsafeMutableRawPointer.allocate(byteCount: bytes,
                                                       alignment: MemoryLayout<T>.alignment)
            storage.append(raw)
            data.withUnsafeBytes { raw.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            var shape = dims
            var value: OpaquePointer?
            let ok = shape.withUnsafeMutableBufferPointer { d in
                check(api, api.pointee.CreateTensorWithDataAsOrtValue(
                    memoryInfo, raw, data.count * MemoryLayout<T>.stride,
                    d.baseAddress, d.count, type, &value))
            }
            guard ok, value != nil else { throw ORTError.failed("could not create input tensor") }
            values.append(value)
        }
        for input in inputs {
            switch input.value {
            case .float(let d, let s): try tensor(d, s, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT)
            case .int64(let d, let s): try tensor(d, s, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64)
            case .int32(let d, let s): try tensor(d, s, ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32)
            }
        }

        // C strings for every name, alive across the call.
        let inC = inputs.map { strdup($0.name) }
        let outC = names.map { strdup($0) }
        defer { (inC + outC).forEach { free($0) } }
        var inPtrs = inC.map { UnsafePointer<CChar>($0) }
        var outPtrs = outC.map { UnsafePointer<CChar>($0) }
        var results = [OpaquePointer?](repeating: nil, count: names.count)
        defer { for r in results where r != nil { api.pointee.ReleaseValue(r) } }
        let ran = values.withUnsafeMutableBufferPointer { vals in
            results.withUnsafeMutableBufferPointer { outs in
                check(api, api.pointee.Run(session, nil,
                                           &inPtrs, vals.baseAddress, vals.count,
                                           &outPtrs, outPtrs.count, outs.baseAddress))
            }
        }
        guard ran else { throw ORTError.failed("Run failed") }

        return try results.map { value -> Output in
            guard let value else { throw ORTError.failed("missing output") }
            var info: OpaquePointer?
            guard check(api, api.pointee.GetTensorTypeAndShape(value, &info)) else {
                throw ORTError.failed("GetTensorTypeAndShape failed")
            }
            defer { api.pointee.ReleaseTensorTypeAndShapeInfo(info) }
            var rank = 0
            _ = check(api, api.pointee.GetDimensionsCount(info, &rank))
            var dims = [Int64](repeating: 0, count: rank)
            _ = check(api, api.pointee.GetDimensions(info, &dims, rank))
            var count = 0
            _ = check(api, api.pointee.GetTensorShapeElementCount(info, &count))
            var type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
            _ = check(api, api.pointee.GetTensorElementType(info, &type))
            var out = Output(shape: dims.map(Int.init))
            guard count > 0 else { return out }
            var raw: UnsafeMutableRawPointer?
            guard check(api, api.pointee.GetTensorMutableData(value, &raw)), let raw else {
                throw ORTError.failed("GetTensorMutableData failed")
            }
            switch type {
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT:
                out.floats = Array(UnsafeBufferPointer(
                    start: raw.bindMemory(to: Float.self, capacity: count), count: count))
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64:
                out.ints = Array(UnsafeBufferPointer(
                    start: raw.bindMemory(to: Int64.self, capacity: count), count: count))
            case ONNX_TENSOR_ELEMENT_DATA_TYPE_INT32:
                out.ints = UnsafeBufferPointer(
                    start: raw.bindMemory(to: Int32.self, capacity: count), count: count).map(Int64.init)
            default:
                throw ORTError.failed("unsupported output element type \(type.rawValue)")
            }
            return out
        }
    }

    func close() {
        if let session { api.pointee.ReleaseSession(session) }
        session = nil
        if let memoryInfo { api.pointee.ReleaseMemoryInfo(memoryInfo) }
        memoryInfo = nil
    }

    deinit { close() }
}

/// True on success. A non-nil OrtStatus is an error: log its message, release
/// it, return false.
private func check(_ api: UnsafePointer<OrtApi>, _ status: OrtStatusPtr?) -> Bool {
    guard let status else { return true }
    let msg = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown"
    Log.warn("ONNX Runtime error: \(msg)")
    api.pointee.ReleaseStatus(status)
    return false
}
