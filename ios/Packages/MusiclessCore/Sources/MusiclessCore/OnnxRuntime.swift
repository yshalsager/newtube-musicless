import Foundation
import onnxruntime

/// Where a session runs. The raw value is the `backend=` field of the `Window pipeline` log line.
public enum InferenceBackend: String, Sendable, CaseIterable {
    /// ONNX Runtime's own CPU kernels.
    case ortCPU = "ort-cpu"
    /// ONNX Runtime with the CoreML execution provider, compute units ALL (CPU, GPU, Neural Engine).
    case ortCoreMLAll = "ort-coreml-all"
    /// ONNX Runtime with the CoreML execution provider, CPU and Neural Engine only (no GPU, so it
    /// can keep running in the background: PRD §4.5).
    case ortCoreMLNeuralEngine = "ort-coreml-ane"
}

public struct OnnxError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}

/// The process-wide ONNX Runtime environment (ORT wants exactly one). Telemetry is off (FR-21).
final class OnnxEnvironment: @unchecked Sendable {  // OrtEnv is thread-safe
    static let shared: Result<OnnxEnvironment, OnnxError> = Result { try OnnxEnvironment() }
        .mapError { $0 as? OnnxError ?? OnnxError(message: "\($0)") }

    let api: UnsafePointer<OrtApi>
    let env: OpaquePointer
    let memoryInfo: OpaquePointer

    private init() throws {
        guard let base = OrtGetApiBase(), let api = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw OnnxError(message: "ONNX Runtime API version \(ORT_API_VERSION) is unavailable")
        }
        self.api = api
        var env: OpaquePointer?
        try Self.check(api, api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "musicless", &env))
        guard let env else { throw OnnxError(message: "CreateEnv returned no environment") }
        self.env = env
        try Self.check(api, api.pointee.DisableTelemetryEvents(env))
        var memoryInfo: OpaquePointer?
        try Self.check(api, api.pointee.CreateCpuMemoryInfo(OrtDeviceAllocator, OrtMemTypeDefault, &memoryInfo))
        guard let memoryInfo else { throw OnnxError(message: "CreateCpuMemoryInfo returned nothing") }
        self.memoryInfo = memoryInfo
    }

    func check(_ status: OpaquePointer?) throws { try Self.check(api, status) }

    static func check(_ api: UnsafePointer<OrtApi>, _ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown ONNX Runtime error"
        api.pointee.ReleaseStatus(status)
        throw OnnxError(message: message)
    }
}

/// One inference session with Android's settings (PRD §4.3, `MusiclessModelHolder.load`): 2 intra-op
/// threads, 1 inter-op, no CPU arena, no memory pattern, no spinning, basic optimisation,
/// `num_splits` = 1. Not thread-safe by design: `ModelRuntime` owns it on one serial executor.
final class OnnxSession {
    let inputName: String
    let outputName: String
    private let environment: OnnxEnvironment
    private let session: OpaquePointer

    init(model: URL, backend: InferenceBackend, coreMLCache: URL?) throws {
        let environment = try OnnxEnvironment.shared.get()
        self.environment = environment
        let api = environment.api
        var options: OpaquePointer?
        try environment.check(api.pointee.CreateSessionOptions(&options))
        guard let options else { throw OnnxError(message: "CreateSessionOptions returned nothing") }
        defer { api.pointee.ReleaseSessionOptions(options) }
        try environment.check(api.pointee.SetIntraOpNumThreads(options, 2))
        try environment.check(api.pointee.SetInterOpNumThreads(options, 1))
        try environment.check(api.pointee.DisableCpuMemArena(options))
        try environment.check(api.pointee.DisableMemPattern(options))
        try environment.check(api.pointee.AddSessionConfigEntry(options, "session.intra_op.allow_spinning", "0"))
        try environment.check(api.pointee.SetSessionGraphOptimizationLevel(options, ORT_ENABLE_BASIC))
        try environment.check(api.pointee.AddFreeDimensionOverrideByName(options, "num_splits", 1))

        if backend != .ortCPU {
            var settings = [
                ("ModelFormat", "MLProgram"),
                ("MLComputeUnits", backend == .ortCoreMLAll ? "ALL" : "CPUAndNeuralEngine"),
            ]
            if let coreMLCache {
                try FileManager.default.createDirectory(at: coreMLCache, withIntermediateDirectories: true)
                settings.append(("ModelCacheDirectory", coreMLCache.path))
            }
            try Self.withCStrings(settings.map(\.0)) { keys in
                try Self.withCStrings(settings.map(\.1)) { values in
                    try environment.check(api.pointee.SessionOptionsAppendExecutionProvider(
                        options, "CoreML", keys, values, settings.count))
                }
            }
        }

        var session: OpaquePointer?
        try environment.check(api.pointee.CreateSession(environment.env, model.path, options, &session))
        guard let session else { throw OnnxError(message: "CreateSession returned nothing") }
        self.session = session
        do {
            inputName = try Self.name(api, environment, session, input: true)
            outputName = try Self.name(api, environment, session, input: false)
        } catch {
            api.pointee.ReleaseSession(session)
            throw error
        }
    }

    deinit { environment.api.pointee.ReleaseSession(session) }

    /// Runs one float tensor through the model; `output` sees a result of the same element count.
    func run(_ input: inout [Float], shape: [Int64], output: (UnsafeBufferPointer<Float>) throws -> Void) throws {
        let api = environment.api, count = input.count
        var tensor: OpaquePointer?
        try input.withUnsafeMutableBytes { bytes in
            try environment.check(api.pointee.CreateTensorWithDataAsOrtValue(
                environment.memoryInfo, bytes.baseAddress, bytes.count, shape, shape.count,
                ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensor))
            guard let tensor else { throw OnnxError(message: "CreateTensorWithDataAsOrtValue returned nothing") }
            defer { api.pointee.ReleaseValue(tensor) }

            var result: OpaquePointer?
            try inputName.withCString { inputName in
                try outputName.withCString { outputName in
                    var inputNames: [UnsafePointer<CChar>?] = [inputName]
                    var outputNames: [UnsafePointer<CChar>?] = [outputName]
                    var inputs: [OpaquePointer?] = [tensor]
                    try environment.check(api.pointee.Run(session, nil, &inputNames, &inputs, 1,
                                                          &outputNames, 1, &result))
                }
            }
            guard let result else { throw OnnxError(message: "Run returned no output") }
            defer { api.pointee.ReleaseValue(result) }
            var data: UnsafeMutableRawPointer?
            try environment.check(api.pointee.GetTensorMutableData(result, &data))
            guard let data else { throw OnnxError(message: "the output tensor has no data") }
            try output(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
        }
    }

    private static func name(_ api: UnsafePointer<OrtApi>, _ environment: OnnxEnvironment,
                             _ session: OpaquePointer, input: Bool) throws -> String {
        var allocator: UnsafeMutablePointer<OrtAllocator>?
        try environment.check(api.pointee.GetAllocatorWithDefaultOptions(&allocator))
        var name: UnsafeMutablePointer<CChar>?
        try environment.check(input ? api.pointee.SessionGetInputName(session, 0, allocator, &name)
                                    : api.pointee.SessionGetOutputName(session, 0, allocator, &name))
        guard let name else { throw OnnxError(message: "the model has no \(input ? "input" : "output")") }
        defer { _ = api.pointee.AllocatorFree(allocator, name) }
        return String(cString: name)
    }

    private static func withCStrings<R>(_ strings: [String],
                                        _ body: (UnsafePointer<UnsafePointer<CChar>?>) throws -> R) rethrows -> R {
        let copies = strings.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        let pointers = copies.map { UnsafePointer<CChar>($0) }
        return try pointers.withUnsafeBufferPointer { try body($0.baseAddress!) }
    }
}
