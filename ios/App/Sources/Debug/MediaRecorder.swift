import Foundation
import MediaPipeline
import YouTubeEngine

/// `--record-media` (US-011 fixtures): init, index and the first two segments of Big Buck Bunny's
/// AAC and smallest H.264 files (CC BY 3.0, Blender Foundation), to Documents/media. Media bytes only:
/// no URL, visitor or address is written.
enum MediaRecorder {
    static let videoID = "aqz-KE-bpKQ"

    static func run() async {
        let log: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
        let transport = InnerTubeTransport(log: log)
        let identity = VisitorIdentity(transport: transport,
                                       storeURL: URL.applicationSupportDirectory.appending(path: "youtube/visitor.json"), log: log)
        guard let visitor = try? await identity.current() else { return log("record-media visitor failed") }
        let locale = RequestLocale.current
        let body = PlayerRequestBody(client: .visionOS, videoID: videoID, cpn: PlayerRequestBody.makeCPN(),
                                     visitorData: visitor.visitorData, signatureTimestamp: await identity.signatureTimestamp(),
                                     acceptLanguage: locale.language, acceptRegion: locale.region,
                                     utcOffsetMinutes: locale.utcOffsetMinutes)
        guard let answer = try? await transport.send(InnerTubeTransport.playerRequest(body), label: "VISIONOS"),
              let parsed = try? PlayerAnswer(json: answer.data) else { return log("record-media no answer") }
        let video = parsed.adaptiveFormats
            .filter { $0.container == "video/mp4" && $0.codecs.hasPrefix("avc1") && $0.url != nil }
            .min { ($0.shortSide ?? .max) < ($1.shortSide ?? .max) }
        let audio = FormatSelector.select(parsed).audio
        let directory = URL.documentsDirectory.appending(path: "media")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest: [[String: Any]] = []
        for format in [audio, video].compactMap({ $0 }) {
            do {
                manifest.append(try await record(format, into: directory, log: log))
            } catch {
                log("record-media itag=\(format.itag) failed: \(error)")
            }
        }
        if let json = try? JSONSerialization.data(withJSONObject: ["video": videoID, "licence": "CC BY 3.0, Blender Foundation",
                                                                   "files": manifest], options: [.prettyPrinted, .sortedKeys]) {
            try? json.write(to: directory.appending(path: "manifest.json"))
        }
        log("record-media done files=\(manifest.count)")
    }

    static func record(_ format: PlayerAnswer.Format, into directory: URL, log: @escaping @Sendable (String) -> Void) async throws -> [String: Any] {
        guard let address = format.url, let url = URL(string: address), let length = format.contentLength,
              let initRange = format.initRange, let indexRange = format.indexRange else { throw URLError(.badURL) }
        let fetcher = MediaFetcher(file: MediaFile(itag: format.itag, lastModified: format.lastModified,
                                                   contentLength: length, url: url), log: log)
        let initData = try await fetcher.read(initRange.start...initRange.end)
        let indexData = try await fetcher.read(indexRange.start...indexRange.end)
        let index = try FMP4Demuxer.parseIndex(indexData, fileOffset: indexRange.start)
        let prefix = "\(format.itag)"
        try initData.write(to: directory.appending(path: "\(prefix)-init.mp4"))
        try indexData.write(to: directory.appending(path: "\(prefix)-index.sidx"))
        var segments: [[String: Any]] = []
        for (number, reference) in index.references.prefix(2).enumerated() {
            let data = try await fetcher.read(reference.bytes)
            try data.write(to: directory.appending(path: "\(prefix)-seg\(number).m4s"))
            segments.append(["start": reference.bytes.lowerBound, "end": reference.bytes.upperBound,
                             "startTime": reference.startTime, "duration": reference.duration])
        }
        log("record-media itag=\(format.itag) mime=\(format.mimeType) init=\(initData.count) index=\(indexData.count) "
            + "references=\(index.references.count) timescale=\(index.timescale) segments=\(segments.map { ($0["end"] as! Int64) - ($0["start"] as! Int64) + 1 })")
        return ["itag": format.itag, "mimeType": format.mimeType, "contentLength": length,
                "initRange": [initRange.start, initRange.end], "indexRange": [indexRange.start, indexRange.end],
                "references": index.references.count, "timescale": index.timescale, "segments": segments]
    }
}
