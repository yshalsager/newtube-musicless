import Compression
import CryptoKit
import Foundation
import Observation

/// One voice-model file of a release: the name it is published under (`<name>.gz` on the server)
/// and the SHA-256 of the decompressed file.
public struct ModelFile: Sendable, Hashable {
    public let name: String
    public let sha256: String

    public init(name: String, sha256: String) {
        self.name = name
        self.sha256 = sha256
    }

    /// Spleeter 2-stems, as `musicless-models-v1` publishes it (PRD §4.3; Android `MusiclessModels.HASHES`).
    public static let spleeter: [ModelFile] = [
        ModelFile(name: "vocals.onnx", sha256: "f6fce89a06c9a98846e1b38e45dcd79ade2c256c3ce11119b33474da726be552"),
        ModelFile(name: "accompaniment.onnx", sha256: "5e3f3048bf2936658a9ab3a9742b2e24765a06cc6c6c7de638aa93ea86330a45"),
    ]
    public static let defaultBaseURL =
        URL(string: "https://github.com/yshalsager/newtube-musicless/releases/download/musicless-models-v1")!
}

public enum ModelStatus: Sendable, Equatable {
    case notDownloaded
    case downloading(percent: Int)
    case ready
    case failed(String)
}

public struct ModelStoreError: Error, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }

    public static let notConfigured = ModelStoreError("Voice model download is not configured in this build")
}

public struct ModelStoreConfiguration: Sendable {
    /// Where `<name>.gz` files are downloaded from; nil means this build has no model source.
    public var baseURL: URL?
    /// Application Support/musicless in the app; excluded from backup.
    public var directory: URL
    public var files: [ModelFile]
    /// Cap on both the gzip download and each decompressed model (Android: 100 MB).
    public var maxBytes: Int64
    public var session: URLSession
    /// Idle timeout per request (Android: 20 s connect and read).
    public var timeout: TimeInterval

    public init(baseURL: URL?, directory: URL, files: [ModelFile] = ModelFile.spleeter,
                maxBytes: Int64 = 100_000_000, session: URLSession = .shared, timeout: TimeInterval = 20) {
        self.baseURL = baseURL
        self.directory = directory
        self.files = files
        self.maxBytes = maxBytes
        self.session = session
        self.timeout = timeout
    }
}

/// Downloads the voice models once and verifies them, so music removal works offline afterwards
/// (US-004). A port of Android's `MusiclessModels`: partial files hold the gzip bytes and resume
/// with `Range`; models are published atomically as `<sha256>-<name>` only after the hash matches.
@MainActor @Observable
public final class ModelStore {
    public private(set) var status: ModelStatus
    /// Decompressed model files in `configuration.files` order, valid once `status == .ready`.
    public nonisolated let modelURLs: [URL]
    @ObservationIgnored private let downloader: ModelDownloader
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(configuration: ModelStoreConfiguration) {
        let downloader = ModelDownloader(configuration: configuration)
        self.downloader = downloader
        modelURLs = configuration.files.map { downloader.publishedURL(for: $0) }
        status = downloader.isReady ? .ready : .notDownloaded
    }

    /// Starts the download unless it is running or done. Also the retry after a failure.
    public func start() {
        guard task == nil, status != .ready else { return }
        guard downloader.isConfigured else {
            status = .failed(ModelStoreError.notConfigured.message)
            return
        }
        status = .downloading(percent: 0)
        task = Task { [downloader] in
            do {
                try await downloader.download { percent in await self.report(percent) }
                status = .ready
            } catch {
                status = .failed("Voice model: \(Self.message(for: error))")
            }
            task = nil
        }
    }

    public func retry() { start() }

    /// The models' size on disk (the published files), 0 before they're downloaded.
    public var bytesOnDisk: Int64 { downloader.bytesOnDisk }

    /// Settings' "Re-download": deletes the models (and any partial download) and fetches them
    /// again. Ignored while a download runs.
    public func redownload() {
        guard task == nil else { return }
        downloader.deleteAll()
        status = .notDownloaded
        start()
    }

    /// Starts the download if needed and waits for its outcome.
    public func awaitReady() async throws {
        start()
        await task?.value
        switch status {
        case .ready: return
        case .failed(let message): throw ModelStoreError(message)
        case .notDownloaded, .downloading: throw ModelStoreError("Voice model download did not finish")
        }
    }

    private func report(_ percent: Int) {
        if case .downloading = status { status = .downloading(percent: percent) }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? ModelStoreError { return error.message }
        return error.localizedDescription
    }
}

// MARK: - Download and verification

/// The file and network work behind `ModelStore`, off the main actor.
struct ModelDownloader: Sendable {
    let configuration: ModelStoreConfiguration

    var isConfigured: Bool { configuration.baseURL != nil }

    var isReady: Bool {
        configuration.files.allSatisfy { FileManager.default.fileExists(atPath: publishedURL(for: $0).path) }
    }

    func publishedURL(for file: ModelFile) -> URL {
        configuration.directory.appendingPathComponent("\(file.sha256)-\(file.name)")
    }

    var bytesOnDisk: Int64 {
        configuration.files.reduce(0) { total, file in
            let size = (try? FileManager.default.attributesOfItem(atPath: publishedURL(for: file).path)[.size] as? NSNumber)?.int64Value
            return total + (size ?? 0)
        }
    }

    func deleteAll() {
        for file in configuration.files {
            try? FileManager.default.removeItem(at: publishedURL(for: file))
            try? FileManager.default.removeItem(at: partialURL(for: file))
        }
    }

    /// `progress` gets 0...99 while downloading, in order, only when the value changes.
    func download(progress: @Sendable (Int) async -> Void) async throws {
        guard let baseURL = configuration.baseURL else { throw ModelStoreError.notConfigured }
        try prepareDirectory()
        var reported = 0
        let count = configuration.files.count
        for (index, file) in configuration.files.enumerated() where !FileManager.default.fileExists(
            atPath: publishedURL(for: file).path) {
            try await fetch(file, from: baseURL) { done, total in
                let next = min(99, (index * 100 + (total > 0 ? Int(done * 100 / total) : 0)) / count)
                if next != reported {
                    reported = next
                    await progress(next)
                }
            }
            try unpackAndVerify(file)
        }
    }

    private func prepareDirectory() throws {
        var directory = configuration.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
    }

    private func partialURL(for file: ModelFile) -> URL {
        configuration.directory.appendingPathComponent(file.name + ".part")
    }

    /// Downloads `<name>.gz` into `<name>.part`, resuming from what is there.
    private func fetch(_ file: ModelFile, from baseURL: URL,
                       progress: (_ done: Int64, _ total: Int64) async -> Void) async throws {
        let partial = partialURL(for: file)
        var offset = (try? FileManager.default.attributesOfItem(atPath: partial.path)[.size] as? Int64) ?? 0
        var request = URLRequest(url: baseURL.appendingPathComponent(file.name + ".gz"),
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: configuration.timeout)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if offset > 0 { request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range") }

        var output: FileHandle?
        defer { try? output?.close() }
        var total: Int64 = -1
        for try await event in StreamingDownload.events(for: request, session: configuration.session) {
            switch event {
            case .response(let response):
                let code = response.statusCode
                // A complete gzip may have been saved before the app was stopped.
                if code == 416 && offset > 0 { return }
                guard code == 200 || code == 206 else { throw ModelStoreError("HTTP \(code)") }
                if code == 206 {
                    let range = response.value(forHTTPHeaderField: "Content-Range") ?? ""
                    guard range.hasPrefix("bytes \(offset)-") else { throw ModelStoreError("Invalid resume response") }
                }
                let append = code == 206 && offset > 0
                if !append { offset = 0 }
                if !FileManager.default.fileExists(atPath: partial.path) {
                    FileManager.default.createFile(atPath: partial.path, contents: nil)
                }
                let handle = try FileHandle(forWritingTo: partial)
                if append { try handle.seekToEnd() } else { try handle.truncate(atOffset: 0) }
                output = handle
                total = response.expectedContentLength < 0 ? -1 : response.expectedContentLength + offset
            case .data(let chunk):
                guard let output else { continue }
                offset += Int64(chunk.count)
                if offset > configuration.maxBytes { throw ModelStoreError("Download too large") }
                try output.write(contentsOf: chunk)
                await progress(offset, total)
            }
        }
        try output?.synchronize()
    }

    /// Gunzips `<name>.part` while hashing it; publishes the model only if the hash matches.
    /// Any failure here deletes the partial file, so the next attempt starts clean.
    private func unpackAndVerify(_ file: ModelFile) throws {
        let fileManager = FileManager.default
        let partial = partialURL(for: file)
        let unpacked = configuration.directory.appendingPathComponent(file.name + ".unpack")
        defer { try? fileManager.removeItem(at: unpacked) }
        do {
            fileManager.createFile(atPath: unpacked.path, contents: nil)
            let output = try FileHandle(forWritingTo: unpacked)
            defer { try? output.close() }
            var hasher = SHA256()
            var size: Int64 = 0
            let limit = configuration.maxBytes
            try Gunzip.decompress(partial) { chunk in
                size += Int64(chunk.count)
                if size > limit { throw ModelStoreError("Model too large") }
                hasher.update(data: chunk)
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard hex == file.sha256 else { throw ModelStoreError("SHA-256 mismatch; tap to retry") }
            var published = publishedURL(for: file)
            // rename(2) replaces atomically: a reader sees the old file or the whole new one.
            guard rename(unpacked.path, published.path) == 0 else { throw ModelStoreError("Cannot publish model") }
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? published.setResourceValues(values)
            try? fileManager.removeItem(at: partial)
        } catch {
            try? fileManager.removeItem(at: partial)
            throw error
        }
    }
}

// MARK: - Streaming URLSession bridge

/// A data task's response and body chunks as an async sequence; cancelling the sequence cancels
/// the task (the size cap stops the download mid-stream, as Android's does).
enum StreamingDownload {
    enum Event: Sendable {
        case response(HTTPURLResponse)
        case data(Data)
    }

    static func events(for request: URLRequest, session: URLSession) -> AsyncThrowingStream<Event, Error> {
        AsyncThrowingStream { continuation in
            let task = session.dataTask(with: request)
            task.delegate = TaskDelegate(continuation: continuation)
            continuation.onTermination = { _ in task.cancel() }
            task.resume()
        }
    }

    /// Lives as the task's delegate; AsyncThrowingStream.Continuation is thread-safe.
    private final class TaskDelegate: NSObject, URLSessionDataDelegate, Sendable {
        let continuation: AsyncThrowingStream<Event, Error>.Continuation

        init(continuation: AsyncThrowingStream<Event, Error>.Continuation) {
            self.continuation = continuation
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
            guard let http = response as? HTTPURLResponse else {
                continuation.finish(throwing: ModelStoreError("Not an HTTP response"))
                return .cancel
            }
            continuation.yield(.response(http))
            return .allow
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(.data(data))
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            continuation.finish(throwing: error)
        }
    }
}

// MARK: - Gzip

/// Streams a single-member gzip file (RFC 1952) through Apple's raw-DEFLATE decoder. The
/// trailer's CRC-32 isn't checked: the SHA-256 of the output covers it.
enum Gunzip {
    static func decompress(_ url: URL, chunk: (Data) throws -> Void) throws {
        let input = try FileHandle(forReadingFrom: url)
        defer { try? input.close() }
        let size = try input.seekToEnd()
        try input.seek(toOffset: 0)
        let head = try input.read(upToCount: 65_536) ?? Data()
        let start = try headerLength(head)
        guard size >= UInt64(start + 8) else { throw ModelStoreError("Not a gzip file") }
        let end = size - 8  // CRC-32 and ISIZE follow the DEFLATE data

        try withoutActuallyEscaping(chunk) { chunk in
            let filter = try OutputFilter(.decompress, using: .zlib) { data in
                if let data, !data.isEmpty { try chunk(data) }
            }
            try input.seek(toOffset: UInt64(start))
            var position = UInt64(start)
            while position < end {
                let count = Int(min(65_536, end - position))
                guard let data = try input.read(upToCount: count), !data.isEmpty else { break }
                try filter.write(data)
                position += UInt64(data.count)
            }
            try filter.finalize()
        }
    }

    /// Length of the gzip header: 10 bytes plus the optional extra, name, comment and header CRC.
    static func headerLength(_ data: Data) throws -> Int {
        let bytes = [UInt8](data.prefix(65_536))
        guard bytes.count >= 10, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else {
            throw ModelStoreError("Not a gzip file")
        }
        let flags = bytes[3]
        var at = 10
        func need(_ count: Int) throws {
            guard at + count <= bytes.count else { throw ModelStoreError("Not a gzip file") }
        }
        if flags & 0x04 != 0 {  // FEXTRA
            try need(2)
            let length = Int(bytes[at]) | Int(bytes[at + 1]) << 8
            at += 2 + length
        }
        for flag: UInt8 in [0x08, 0x10] where flags & flag != 0 {  // FNAME, FCOMMENT: zero-terminated
            while true {
                try need(1)
                at += 1
                if bytes[at - 1] == 0 { break }
            }
        }
        if flags & 0x02 != 0 { at += 2 }  // FHCRC
        try need(0)
        return at
    }
}
