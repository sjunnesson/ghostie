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
    static let shared: ORTRuntime? = {
        for path in dylibCandidates() where FileManager.default.fileExists(atPath: path) {
            if let rt = ORTRuntime(dylibPath: path) { return rt }
        }
        return nil
    }()

    let dylibPath: String
    private let api: UnsafePointer<OrtApi>
    private var env: OpaquePointer?

    private init?(dylibPath: String) {
        guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_LOCAL) else { return nil }
        typealias GetApiBaseFn = @convention(c) () -> UnsafePointer<OrtApiBase>?
        guard let sym = dlsym(handle, "OrtGetApiBase") else { return nil }
        let getBase = unsafeBitCast(sym, to: GetApiBaseFn.self)
        guard let base = getBase() else { return nil }
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
        guard let api = table else { return nil }
        self.dylibPath = dylibPath
        self.api = api
        var env: OpaquePointer?
        guard check(api, api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "ghostie", &env)),
              env != nil else { return nil }
        self.env = env
    }

    deinit {
        if let env { api.pointee.ReleaseEnv(env) }
    }

    func makeSession(modelPath: String) throws -> ORTSession {
        try ORTSession(api: api, env: env, modelPath: modelPath)
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

    init(api: UnsafePointer<OrtApi>, env: OpaquePointer?, modelPath: String) throws {
        self.api = api

        var options: OpaquePointer?
        guard check(api, api.pointee.CreateSessionOptions(&options)) else {
            throw ORTError.failed("CreateSessionOptions failed")
        }
        defer { api.pointee.ReleaseSessionOptions(options) }
        _ = check(api, api.pointee.SetIntraOpNumThreads(options, 2))

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
    func run(wav: [Float]) throws -> [Float] {
        guard !wav.isEmpty else { throw ORTError.failed("empty input") }
        var input: OpaquePointer?
        var shape: [Int64] = [1, Int64(wav.count)]
        var data = wav
        let created = data.withUnsafeMutableBytes { buf in
            shape.withUnsafeMutableBufferPointer { dims in
                check(api, api.pointee.CreateTensorWithDataAsOrtValue(
                    memoryInfo, buf.baseAddress, buf.count,
                    dims.baseAddress, 2,
                    ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &input))
            }
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
