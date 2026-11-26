import Foundation
import MediaPipeline
import YouTubeEngine

/// `--fetch-check` (US-010): resolve videos with VISIONOS, then fetch their AAC files through
/// MediaFetcher, timing the first chunk against a 2 MiB first request, the whole file, and the host
/// fallback. Lines go to the log; nothing is stored.
enum FetchCheckRunner {
    static let videos = ["dQw4w9WgXcQ", "9bZkp7q19f0", "JGwWNGJdvx8"]

    static func run() async {
        let log: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
        let transport = InnerTubeTransport(log: log)
        let identity = VisitorIdentity(transport: transport,
                                       storeURL: URL.applicationSupportDirectory.appending(path: "youtube/visitor.json"), log: log)
        guard let visitor = try? await identity.current() else { return log("fetch-check visitor failed") }
        let timestamp = await identity.signatureTimestamp()
        let locale = RequestLocale.current
        for videoID in videos {
            let body = PlayerRequestBody(client: .visionOS, videoID: videoID, cpn: PlayerRequestBody.makeCPN(),
                                         visitorData: visitor.visitorData, signatureTimestamp: timestamp,
                                         acceptLanguage: locale.language, acceptRegion: locale.region,
                                         utcOffsetMinutes: locale.utcOffsetMinutes)
            guard let answer = try? await transport.send(InnerTubeTransport.playerRequest(body), label: "VISIONOS"),
                  let parsed = try? PlayerAnswer(json: answer.data),
                  let audio = FormatSelector.select(parsed).audio, let address = audio.url, let url = URL(string: address),
                  let length = audio.contentLength else {
                log("fetch-check video=\(videoID) unresolved")
                continue
            }
            let file = MediaFile(itag: audio.itag, lastModified: audio.lastModified, contentLength: length, url: url)

            // A 2 MiB first request, for comparison with the 256 KiB first chunk (separate fetcher: same host book).
            let probe = MediaFetcher(file: file, log: log)
            let bigStart = ContinuousClock.now
            let big = try? await probe.read(0...min(2 * 1024 * 1024, length) - 1)
            let bigMs = Int((ContinuousClock.now - bigStart) / .milliseconds(1))

            let fetcher = MediaFetcher(file: file, log: log)
            let start = ContinuousClock.now
            var firstMs = -1, bytes = 0, chunks = 0
            do {
                for try await chunk in fetcher.chunks() {
                    if firstMs < 0 { firstMs = Int((ContinuousClock.now - start) / .milliseconds(1)) }
                    bytes += chunk.data.count
                    chunks += 1
                }
                let totalMs = Int((ContinuousClock.now - start) / .milliseconds(1))
                let rate = Double(bytes) / 1_048_576 / max(Double(totalMs) / 1000, 0.001)
                log("fetch-check video=\(videoID) itag=\(audio.itag) bytes=\(bytes) chunks=\(chunks) firstChunkMs=\(firstMs) "
                    + "first2MiBMs=\(big == nil ? -1 : bigMs) totalMs=\(totalMs) MiBps=\(String(format: "%.1f", rate))")
            } catch {
                log("fetch-check video=\(videoID) failed after \(bytes) bytes: \(error)")
            }
        }
        log("fetch-check done")
    }
}
