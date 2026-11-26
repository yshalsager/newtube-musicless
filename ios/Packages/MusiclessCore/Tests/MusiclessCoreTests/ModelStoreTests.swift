import Compression
import CryptoKit
import Foundation
import MusiclessCore
import os
import Testing

/// US-004, mirroring Android's MusiclessModelsTest: fresh download, resume (206), 416 on resume,
/// a bad Content-Range, a server that ignores Range, a hash mismatch, both size caps, HTTP errors,
/// an unconfigured build, already-present models, and retry.
@MainActor @Suite struct ModelStoreTests {
    @Test func freshDownloadPublishesVerifiedModelsExcludedFromBackup() async throws {
        let env = try StubEnvironment()
        env.serve { request, file in .ok(env.gzip(file)) }
        let store = env.store()
        #expect(store.status == .notDownloaded)

        try await store.awaitReady()

        #expect(store.status == .ready)
        for (url, file) in zip(store.modelURLs, env.files) {
            #expect(try Data(contentsOf: url) == env.payloads[file.name])
            #expect(url.lastPathComponent == "\(file.sha256)-\(file.name)")
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        #expect(env.leftovers().isEmpty)
        #expect(env.requests().allSatisfy { $0.value(forHTTPHeaderField: "Range") == nil })
        #expect(env.requests().allSatisfy { $0.value(forHTTPHeaderField: "Accept-Encoding") == "identity" })
    }

    @Test func sizeAndRedownloadForSettings() async throws {
        let env = try StubEnvironment()
        env.serve { request, file in .ok(env.gzip(file)) }
        let store = env.store()
        #expect(store.bytesOnDisk == 0)
        try await store.awaitReady()
        let expected = env.files.reduce(Int64(0)) { $0 + Int64(env.payloads[$1.name]?.count ?? 0) }
        #expect(store.bytesOnDisk == expected)
        let before = env.requests().count
        store.redownload()
        #expect(store.status == .downloading(percent: 0))
        try await store.awaitReady()
        #expect(store.status == .ready && store.bytesOnDisk == expected)
        #expect(env.requests().count == before + env.files.count, "every model fetched again")
    }

    @Test func resumesPartialGzipWith206() async throws {
        let env = try StubEnvironment()
        let vocals = env.files[0], gzip = env.gzip(vocals)
        try env.writePartial(vocals, gzip.prefix(50_000))
        env.serve { request, file in
            guard file == vocals else { return .ok(env.gzip(file)) }
            guard request.value(forHTTPHeaderField: "Range") == "bytes=50000-" else { return .status(500) }
            return .partial(gzip, from: 50_000)
        }
        let store = env.store()
        try await store.awaitReady()
        #expect(try Data(contentsOf: store.modelURLs[0]) == env.payloads[vocals.name])
        #expect(env.leftovers().isEmpty)
    }

    @Test func rangeNotSatisfiableOnResumeMeansTheGzipIsComplete() async throws {
        let env = try StubEnvironment()
        let vocals = env.files[0]
        try env.writePartial(vocals, env.gzip(vocals))
        env.serve { request, file in
            file == vocals ? .status(416) : .ok(env.gzip(file))
        }
        let store = env.store()
        try await store.awaitReady()
        #expect(try Data(contentsOf: store.modelURLs[0]) == env.payloads[vocals.name])
    }

    @Test func badContentRangeFailsAndKeepsNothingPublished() async throws {
        let env = try StubEnvironment()
        let vocals = env.files[0], gzip = env.gzip(vocals)
        try env.writePartial(vocals, gzip.prefix(50_000))
        env.serve { request, file in .partial(gzip, from: 0) }  // ignores the asked offset
        let store = env.store()
        await #expect(throws: ModelStoreError("Voice model: Invalid resume response")) { try await store.awaitReady() }
        #expect(store.status == .failed("Voice model: Invalid resume response"))
        #expect(!FileManager.default.fileExists(atPath: store.modelURLs[0].path))
    }

    @Test func serverIgnoringRangeRestartsInsteadOfAppending() async throws {
        let env = try StubEnvironment()
        let vocals = env.files[0]
        try env.writePartial(vocals, Data([1, 2, 3]))
        env.serve { request, file in .ok(env.gzip(file)) }
        let store = env.store()
        try await store.awaitReady()
        #expect(try Data(contentsOf: store.modelURLs[0]) == env.payloads[vocals.name])
    }

    @Test func shaMismatchFailsAndDeletesPartialAndUnpackedFiles() async throws {
        let env = try StubEnvironment(corruptHashOf: "vocals.onnx")
        env.serve { request, file in .ok(env.gzip(file)) }
        let store = env.store()
        await #expect(throws: ModelStoreError("Voice model: SHA-256 mismatch; tap to retry")) {
            try await store.awaitReady()
        }
        #expect(env.leftovers().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: store.modelURLs[0].path))
    }

    @Test func downloadCapStopsAnOversizedGzip() async throws {
        let env = try StubEnvironment(maxBytes: 100_000)  // the payloads gzip to ~200 KB
        env.serve { request, file in .ok(env.gzip(file)) }
        let store = env.store()
        await #expect(throws: ModelStoreError("Voice model: Download too large")) { try await store.awaitReady() }
    }

    @Test func decompressedCapStopsAGzipBomb() async throws {
        let env = try StubEnvironment(maxBytes: 100_000, payload: { _ in Data(count: 300_000) })
        env.serve { request, file in .ok(env.gzip(file)) }
        let store = env.store()
        await #expect(throws: ModelStoreError("Voice model: Model too large")) { try await store.awaitReady() }
        #expect(env.leftovers().isEmpty)
    }

    @Test func httpErrorIsReportedAndRetryRecovers() async throws {
        let env = try StubEnvironment()
        let failing = OSAllocatedUnfairLock(initialState: true)
        env.serve { request, file in
            failing.withLock { $0 } ? .status(404) : .ok(env.gzip(file))
        }
        let store = env.store()
        await #expect(throws: ModelStoreError("Voice model: HTTP 404")) { try await store.awaitReady() }
        #expect(store.status == .failed("Voice model: HTTP 404"))

        failing.withLock { $0 = false }
        store.retry()
        try await store.awaitReady()
        #expect(store.status == .ready)
    }

    @Test func unconfiguredBuildFailsWithoutCreatingFiles() async throws {
        let env = try StubEnvironment()
        let store = ModelStore(configuration: env.configuration(baseURL: nil))
        store.start()
        #expect(store.status == .failed("Voice model download is not configured in this build"))
        #expect(!FileManager.default.fileExists(atPath: env.directory.path))
        #expect(env.requests().isEmpty)
    }

    @Test func modelsAlreadyPresentAreReadyWithoutAnyRequest() async throws {
        let env = try StubEnvironment()
        try FileManager.default.createDirectory(at: env.directory, withIntermediateDirectories: true)
        for file in env.files {
            try env.payloads[file.name]!.write(to: env.directory.appendingPathComponent("\(file.sha256)-\(file.name)"))
        }
        let store = env.store()
        #expect(store.status == .ready)
        try await store.awaitReady()
        #expect(env.requests().isEmpty)
    }

    @Test func gzipHeaderWithFileNameIsParsed() async throws {
        let env = try StubEnvironment()
        env.serve { request, file in .ok(env.gzip(file, fileName: file.name)) }
        let store = env.store()
        try await store.awaitReady()
        #expect(try Data(contentsOf: store.modelURLs[1]) == env.payloads[env.files[1].name])
    }

    /// Opt-in: downloads the real release into ios/.models (gitignored), which US-005's tests use.
    /// `MUSICLESS_LIVE_MODELS=1 swift test --package-path ios/Packages/MusiclessCore --filter liveRelease`
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MUSICLESS_LIVE_MODELS"] == "1"))
    func liveReleaseDownloadsAndVerifies() async throws {
        let store = ModelStore(configuration: ModelStoreConfiguration(
            baseURL: ModelFile.defaultBaseURL, directory: LocalModels.directory))
        try await store.awaitReady()
        #expect(store.status == .ready)
        for url in store.modelURLs {
            print("live model: \(url.lastPathComponent) \(try FileManager.default.attributesOfItem(atPath: url.path)[.size] ?? 0) bytes")
        }
    }
}

/// ios/.models, where the Mac keeps the real models for tests (never committed).
enum LocalModels {
    static let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MusiclessCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // MusiclessCore
        .deletingLastPathComponent()   // Packages
        .deletingLastPathComponent()   // ios
        .appendingPathComponent(".models", isDirectory: true)
}

// MARK: - Test environment

/// A temporary directory, two small models and a stub server on a host only this test uses.
struct StubEnvironment: Sendable {
    let host = "models-\(UUID().uuidString.lowercased()).test"
    let directory: URL
    let files: [ModelFile]
    let payloads: [String: Data]
    let maxBytes: Int64

    init(maxBytes: Int64 = 100_000_000, corruptHashOf corrupt: String? = nil,
         payload: (String) -> Data = { StubEnvironment.noise(seed: $0, count: 200_000) }) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-store-\(UUID().uuidString)", isDirectory: true)
        var payloads: [String: Data] = [:]
        var files: [ModelFile] = []
        for name in ["vocals.onnx", "accompaniment.onnx"] {
            let data = payload(name)
            payloads[name] = data
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            files.append(ModelFile(name: name, sha256: name == corrupt ? String(hash.reversed()) : hash))
        }
        self.payloads = payloads
        self.files = files
        self.maxBytes = maxBytes
    }

    func configuration(baseURL: URL?) -> ModelStoreConfiguration {
        let session = URLSessionConfiguration.ephemeral
        session.protocolClasses = [StubURLProtocol.self]
        return ModelStoreConfiguration(baseURL: baseURL, directory: directory, files: files, maxBytes: maxBytes,
                                       session: URLSession(configuration: session), timeout: 5)
    }

    @MainActor func store() -> ModelStore {
        ModelStore(configuration: configuration(baseURL: URL(string: "https://\(host)/release")!))
    }

    func serve(_ handler: @escaping @Sendable (URLRequest, ModelFile) -> StubReply) {
        let files = self.files
        StubRegistry.shared.register(host: host) { request in
            guard let name = request.url?.lastPathComponent, name.hasSuffix(".gz"),
                  let file = files.first(where: { $0.name + ".gz" == name }) else { return .status(404) }
            return handler(request, file)
        }
    }

    func requests() -> [URLRequest] { StubRegistry.shared.requests(host: host) }

    func gzip(_ file: ModelFile, fileName: String? = nil) -> Data {
        TestGzip.compress(payloads[file.name]!, fileName: fileName)
    }

    func writePartial(_ file: ModelFile, _ data: Data) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(file.name + ".part"))
    }

    /// Partial and unpacked files left in the directory.
    func leftovers() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
            .filter { $0.hasSuffix(".part") || $0.hasSuffix(".unpack") }
    }

    /// Incompressible deterministic bytes (xorshift32 seeded from the name).
    static func noise(seed: String, count: Int) -> Data {
        var state: UInt32 = seed.utf8.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 } | 1
        var data = Data(count: count)
        for i in 0..<count {
            state ^= state << 13
            state ^= state >> 17
            state ^= state << 5
            data[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
        return data
    }
}

struct StubReply: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    static func ok(_ body: Data) -> StubReply {
        StubReply(status: 200, headers: ["Content-Length": "\(body.count)"], body: body)
    }

    static func partial(_ whole: Data, from offset: Int) -> StubReply {
        let body = whole.subdata(in: offset..<whole.count)
        return StubReply(status: 206, headers: [
            "Content-Length": "\(body.count)",
            "Content-Range": "bytes \(offset)-\(whole.count - 1)/\(whole.count)",
        ], body: body)
    }

    static func status(_ code: Int) -> StubReply { StubReply(status: code, headers: [:], body: Data()) }
}

final class StubRegistry: Sendable {
    static let shared = StubRegistry()
    private struct State {
        var handlers: [String: @Sendable (URLRequest) -> StubReply] = [:]
        var requests: [String: [URLRequest]] = [:]
    }
    private let state = OSAllocatedUnfairLock(initialState: State())

    func register(host: String, handler: @escaping @Sendable (URLRequest) -> StubReply) {
        state.withLock { $0.handlers[host] = handler }
    }

    func requests(host: String) -> [URLRequest] { state.withLock { $0.requests[host] ?? [] } }

    func reply(to request: URLRequest) -> StubReply? {
        guard let host = request.url?.host else { return nil }
        let handler = state.withLock { state -> (@Sendable (URLRequest) -> StubReply)? in
            state.requests[host, default: []].append(request)
            return state.handlers[host]
        }
        return handler?(request)
    }
}

/// Serves StubRegistry replies, the body in 16 KB chunks so the store streams it.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let reply = StubRegistry.shared.reply(to: request),
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                             headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < reply.body.count {
            let end = min(offset + 16_384, reply.body.count)
            client?.urlProtocol(self, didLoad: reply.body.subdata(in: offset..<end))
            offset = end
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// A minimal gzip writer (RFC 1952) for fixtures: header, raw DEFLATE, CRC-32 and size.
enum TestGzip {
    static func compress(_ data: Data, fileName: String? = nil) -> Data {
        var out = Data([0x1F, 0x8B, 8, fileName == nil ? 0 : 0x08, 0, 0, 0, 0, 0, 255])
        if let fileName { out += Data(fileName.utf8) + [0] }
        var deflated = Data()
        do {
            let filter = try OutputFilter(.compress, using: .zlib) { chunk in
                if let chunk { deflated.append(chunk) }
            }
            try filter.write(data)
            try filter.finalize()
        } catch {
            fatalError("deflate failed: \(error)")
        }
        out += deflated
        for value in [crc32(data), UInt32(truncatingIfNeeded: data.count)] {
            out += withUnsafeBytes(of: value.littleEndian) { Data($0) }
        }
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
        }
        return ~crc
    }
}
