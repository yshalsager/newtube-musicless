import BackgroundTasks
import Foundation
import MediaPipeline
import Observation
import YouTubeEngine

/// One download (US-028), persisted.
struct DownloadItem: Codable, Identifiable, Equatable {
    enum State: Codable, Equatable {
        case queued
        case downloading(Double)
        case removingMusic(Double)
        case saving
        case done(file: String)
        case failed(String)
    }

    var id: UUID
    var videoID: String
    var title: String
    var author: String
    var thumbnail: URL?
    /// The chosen quality's label; nil for "Best", shown in the current language.
    var quality: String?
    var itag: Int?
    /// Saved with the music removed: playing it uses pass-through.
    var voicesOnly: Bool
    var state: State
    var createdAt: Date

    var qualityLabel: String { quality ?? String(localized: "Best") }

    var fileURL: URL? {
        if case .done(let file) = state { URL.documentsDirectory.appending(path: file) } else { nil }
    }

    var isActive: Bool {
        switch state {
        case .queued, .downloading, .removingMusic, .saving: true
        case .done, .failed: false
        }
    }
}

/// Downloads with the music removed (US-028): pick a quality, fetch both files through the media
/// fetcher with playback's 403 recovery, remove the music offline, mux one MP4 into Documents
/// (Files → On My iPhone → the app). One at a time. On iOS 26 each runs inside a
/// `BGContinuedProcessingTask` with the system's progress UI.
@MainActor @Observable
final class DownloadStore {
    static let shared = DownloadStore()

    private(set) var items: [DownloadItem] = []
    @ObservationIgnored private let storeURL = URL.applicationSupportDirectory.appending(path: "downloads.json")
    @ObservationIgnored private var running: Task<Void, Never>?
    @ObservationIgnored private var runningID: UUID?
    @ObservationIgnored private var backgroundTask: AnyObject?

    private init() {
        if let data = try? Data(contentsOf: storeURL), let saved = try? JSONDecoder().decode([DownloadItem].self, from: data) {
            // A download the app was closed in the middle of didn't finish.
            items = saved.map { item in
                var item = item
                if item.isActive { item.state = .failed(String(localized: "Interrupted. Try again.")) }
                return item
            }
        }
    }

    func start(videoID: String, title: String, author: String, thumbnail: URL?, option: VideoOption?) {
        let item = DownloadItem(id: UUID(), videoID: videoID, title: title, author: author, thumbnail: thumbnail,
                                quality: option?.label, itag: option?.itag,
                                voicesOnly: AppSettings.shared.removeMusic, state: .queued, createdAt: Date())
        items.insert(item, at: 0)
        save()
        AppLog.player.info("download queued video=\(videoID) quality=\(item.quality ?? "best") voicesOnly=\(item.voicesOnly)")
        next()
    }

    func retry(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = .queued
        items[index].voicesOnly = AppSettings.shared.removeMusic
        save()
        next()
    }

    func cancel(_ id: UUID) {
        if runningID == id {
            running?.cancel()
        } else if let index = items.firstIndex(where: { $0.id == id }), items[index].isActive {
            items[index].state = .failed(String(localized: "Cancelled"))
            save()
        }
    }

    func delete(_ id: UUID) {
        cancel(id)
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let url = items[index].fileURL { try? FileManager.default.removeItem(at: url) }
        items.remove(at: index)
        save()
    }

    // MARK: Running

    private func next() {
        guard running == nil, let item = items.last(where: { $0.state == .queued }) else { return }
        runningID = item.id
        beginBackgroundTask(for: item)
        running = Task {
            let outcome: DownloadItem.State
            do {
                let file = try await DownloadJob(item: item) { [weak self] state in
                    Task { @MainActor in self?.update(item.id, state) }
                }.run()
                outcome = .done(file: file)
                AppLog.player.info("download done video=\(item.videoID) file=\(file.count) chars")
            } catch is CancellationError {
                outcome = .failed(String(localized: "Cancelled"))
            } catch {
                AppLog.player.info("download failed video=\(item.videoID) error=\(error)")
                outcome = .failed((error as? DownloadError)?.description == "separation failed"
                                  ? String(localized: "Couldn't remove the music") : String(localized: "Download failed. Try again."))
            }
            update(item.id, outcome)
            endBackgroundTask(success: { if case .done = outcome { true } else { false } }())
            running = nil
            runningID = nil
            next()
        }
    }

    private func update(_ id: UUID, _ state: DownloadItem.State) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].state = state
        if #available(iOS 26, *), let task = backgroundTask as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = Int64(Self.overall(state) * 1000)
        }
        if !items[index].isActive { save() }
    }

    /// One bar for the system: fetching is the first 60 %, separating the next 35 %, saving the rest.
    static func overall(_ state: DownloadItem.State) -> Double {
        switch state {
        case .queued: 0
        case .downloading(let fraction): fraction * 0.6
        case .removingMusic(let fraction): 0.6 + fraction * 0.35
        case .saving: 0.95
        case .done, .failed: 1
        }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(items).write(to: storeURL, options: .atomic)
    }

    // MARK: BGContinuedProcessingTask (iOS 26)

    private func beginBackgroundTask(for item: DownloadItem) {
        guard #available(iOS 26, *), let bundle = Bundle.main.bundleIdentifier else { return }
        let identifier = "\(bundle).download.\(item.id.uuidString)"
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let task = task as? BGContinuedProcessingTask else { return }
            MainActor.assumeIsolated {
                task.progress.totalUnitCount = 1000
                task.expirationHandler = { [weak self] in
                    Task { @MainActor in
                        AppLog.player.info("download background-task expired")
                        self?.running?.cancel()
                    }
                }
                self?.backgroundTask = task
                AppLog.player.info("download background-task running")
            }
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: String(localized: "Downloading"),
                                                       subtitle: item.title)
        request.strategy = .queue
        do {
            try BGTaskScheduler.shared.submit(request)
            AppLog.player.info("download background-task submitted registered=\(registered)")
        } catch {
            AppLog.player.info("download background-task refused error=\(error)")
        }
    }

    private func endBackgroundTask(success: Bool) {
        guard #available(iOS 26, *), let task = backgroundTask as? BGContinuedProcessingTask else { return }
        task.setTaskCompleted(success: success)
        backgroundTask = nil
    }
}

/// The work of one download, off the main actor except for resolving (the resolver is main-actor).
struct DownloadJob: Sendable {
    let item: DownloadItem
    let report: @Sendable (DownloadItem.State) -> Void

    init(item: DownloadItem, report: @escaping @Sendable (DownloadItem.State) -> Void) {
        self.item = item
        self.report = report
    }

    func run() async throws -> String {
        let work = FileManager.default.temporaryDirectory.appending(path: "download-\(item.id.uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        report(.downloading(0))
        let media = try await resolve()
        // What a recovery blames and repoints, shared by both files (PlaybackServices' PlayingFiles).
        let playing = PlayingFiles(media)
        let audioURL = work.appending(path: "audio.m4a"), videoURL = work.appending(path: "video.mp4")
        let total = Double(media.audio.file.contentLength + (media.video?.file.contentLength ?? 0))
        let audioBytes = media.audio.file.contentLength
        let pending = try await fetch(.audio, source: media.audio, playing: playing, to: audioURL) { bytes in
            report(.downloading(min(1, Double(bytes) / total)))
        }
        if var video = media.video {
            // A recovery during the audio also answered for the picture: start from its link.
            var fetcher: MediaFetcher?
            switch pending {
            case .same(let file)?: video.file = file
            case .replacement(let source, let replacement)?: video = source; fetcher = replacement
            case nil: break
            }
            _ = try await fetch(.video, source: video, fetcher: fetcher, playing: playing, to: videoURL) { bytes in
                report(.downloading(min(1, Double(audioBytes + bytes) / total)))
            }
        }
        var audioForMux = audioURL
        if item.voicesOnly {
            report(.removingMusic(0))
            let voicesURL = work.appending(path: "voices.m4a")
            let start = ContinuousClock.now
            do {
                let backend = try await PlaybackServices.shared.downloadBackend()
                try await OfflineSeparator.run(input: audioURL, output: voicesURL, backend: backend) { fraction in
                    report(.removingMusic(fraction))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Any failure here (models, reader, a failed window, the writer) is "Couldn't remove the music".
                AppLog.musicless.info("download voices failed video=\(item.videoID) error=\(error)")
                throw DownloadError(description: "separation failed")
            }
            AppLog.musicless.info("download voices video=\(item.videoID) ms=\(Int((ContinuousClock.now - start) / .milliseconds(1)))")
            audioForMux = voicesURL
        }
        report(.saving)
        let name = Self.fileName(title: item.title, videoID: item.videoID)
        try await Muxer.mux(video: media.video == nil ? nil : videoURL, audio: audioForMux, to: URL.documentsDirectory.appending(path: name))
        return name
    }

    /// `--synthetic-wall` (US-017's debug wall, for downloads too): the first answer's links refuse
    /// every request starting at 60 s of stream or later, and its walls go to the separate book.
    private static var synthetic: Bool { ProcessInfo.processInfo.arguments.contains("--synthetic-wall") }
    private static let step: Int64 = 4 * 1024 * 1024

    /// The answer's files at the chosen quality (`itag`, else the settings' choice).
    private func resolve() async throws -> ResolvedMedia {
        var media = try await VideoResolver.media(for: item.videoID, withVideo: true, synthetic: Self.synthetic)
        if let itag = item.itag, let option = media.videoOptions.first(where: { $0.itag == itag }) {
            media.video = option.source
            media.videoItag = itag
        }
        return media
    }

    /// The whole file in 4 MB ranges through the media fetcher. A 403 is routine and gets
    /// playback's recovery (`VideoResolver.recover`): the wall rule reads the refusal in stream time
    /// (from the file's sidx), the refusing source is blamed and asked last, and the new answer's
    /// copy of the same file (itag, lmt, length) takes over at the same offset. When it has no copy,
    /// its replacement starts over. The refused URL is never asked again. Returns what the last
    /// recovery offered for the other track, if anything.
    private func fetch(_ track: MediaRefusal.Track, source: FMP4Source, fetcher given: MediaFetcher? = nil,
                       playing: PlayingFiles, to url: URL,
                       progress: @Sendable (Int64) -> Void) async throws -> RecoveredFiles.Track? {
        let log: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
        var source = source
        var fetcher = given ?? MediaFetcher(file: source.file, log: log)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        var offset: Int64 = 0
        var index: FMP4SegmentIndex?
        var servedStarts: [Int64] = []
        var wall: Int64?
        var recoveries = 0
        var other: RecoveredFiles.Track?
        while offset < source.file.contentLength {
            try Task.checkCancellation()
            var end = min(offset + Self.step, source.file.contentLength) - 1
            // A request that starts below the wall and runs past it would be served (googlevideo
            // refuses by a request's start), so the synthetic wall ends one there.
            if let wall, offset < wall { end = min(end, wall - 1) }
            do {
                let data = try await fetcher.read(offset...end)
                try handle.write(contentsOf: data)
                servedStarts.append(offset)
                offset += Int64(data.count)
                progress(offset)
                if index == nil, offset > source.indexRange.upperBound {
                    index = Self.readIndex(url, source.indexRange)
                    if Self.synthetic, let index,
                       let reference = index.references.first(where: { index.seconds($0.startTime) >= 60 }) {
                        wall = reference.bytes.lowerBound
                        await fetcher.setSyntheticRefusal(fromByte: reference.bytes.lowerBound)
                        log("download synthetic-wall track=\(track.rawValue) byte=\(reference.bytes.lowerBound)")
                    }
                }
            } catch let refused as MediaRefused {
                recoveries += 1
                guard recoveries <= 3 else { throw refused }
                let refusal = MediaRefusal(track: track, itag: refused.itag, forbiddenMs: Self.streamMs(offset, index),
                                           lowestServedMs: servedStarts.first.map { Self.streamMs($0, index) } ?? -1,
                                           highestServedMs: servedStarts.last.map { Self.streamMs($0, index) } ?? -1)
                log("download media403 track=\(track.rawValue) itag=\(refused.itag) at=\(offset) forbiddenMs=\(refusal.forbiddenMs) "
                    + "recovery=\(recoveries)")
                guard let recovered = await VideoResolver.recover(videoID: item.videoID, playing: playing, refusal: refusal,
                                                                  synthetic: Self.synthetic),
                      let next = track == .audio ? recovered.audio : recovered.video
                else { throw refused }
                other = track == .audio ? recovered.video : recovered.audio
                wall = nil
                switch next {
                case .same(let file):
                    try await fetcher.repoint(to: file)
                    source.file = file
                    log("download resumed track=\(track.rawValue) itag=\(file.itag) at=\(offset)")
                case .replacement(let replacement, let replacementFetcher):
                    // Another file: what was written belongs to the old one; start over with it.
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                    offset = 0
                    index = nil
                    servedStarts = []
                    source = replacement
                    fetcher = replacementFetcher
                    log("download restarted track=\(track.rawValue) itag=\(replacement.file.itag)")
                }
            }
        }
        return other
    }

    /// The file's sidx, from the bytes already written.
    private static func readIndex(_ url: URL, _ range: ClosedRange<Int64>) -> FMP4SegmentIndex? {
        guard let reader = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? reader.close() }
        guard (try? reader.seek(toOffset: UInt64(range.lowerBound))) != nil,
              let data = try? reader.read(upToCount: Int(range.upperBound - range.lowerBound + 1)) else { return nil }
        return try? FMP4Demuxer.parseIndex(data, fileOffset: range.lowerBound)
    }

    /// Where a byte falls in stream time: the start of its sidx segment (0 before the first one).
    private static func streamMs(_ byte: Int64, _ index: FMP4SegmentIndex?) -> Int64 {
        guard let index else { return 0 }
        guard let reference = index.references.last(where: { $0.bytes.lowerBound <= byte }) else { return 0 }
        return Int64(index.seconds(reference.startTime) * 1000)
    }

    /// `<title>.mp4` in Documents, without characters Files refuses, never overwriting.
    static func fileName(title: String, videoID: String) -> String {
        let cleaned = title.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>\n\r")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        let base = String((cleaned.isEmpty ? videoID : cleaned).prefix(100))
        var name = "\(base).mp4"
        var index = 2
        while FileManager.default.fileExists(atPath: URL.documentsDirectory.appending(path: name).path) {
            name = "\(base) (\(index)).mp4"
            index += 1
        }
        return name
    }
}
