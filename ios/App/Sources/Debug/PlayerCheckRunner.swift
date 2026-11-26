import Foundation
import YouTubeEngine

/// Runs `PlayerCheck` (US-008) from the `--player-check` launch argument; results go to the log.
enum PlayerCheckRunner {
    /// `--resolve-check` (10 videos, one request each) and `--record-answers` (fixtures to Documents/answers).
    static func runUS009(record: Bool) async {
        let log: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
        let transport = InnerTubeTransport(log: log)
        let store = URL.applicationSupportDirectory.appending(path: "youtube/visitor.json")
        let identity = VisitorIdentity(transport: transport, storeURL: store, log: log)
        if record {
            await PlayerCheck.record(into: URL.documentsDirectory.appending(path: "answers"),
                                     transport: transport, identity: identity, log: log)
        } else {
            await PlayerCheck.resolve(transport: transport, identity: identity, log: log)
        }
    }

    static func run() async {
        let log: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
        let transport = InnerTubeTransport(log: log)
        let store = URL.applicationSupportDirectory.appending(path: "youtube/visitor.json")
        let identity = VisitorIdentity(transport: transport, storeURL: store, log: log)
        let media = URLSession(configuration: .ephemeral)
        let lines = await PlayerCheck.run(transport: transport, identity: identity, media: media, log: log)
        let served = lines.filter { $0.mediaStatus == 206 }
        log("player-check done answers=\(lines.count) mediaServed=\(served.count) "
            + "minusOneServed=\(served.filter { $0.signatureTimestamp == -1 }.count)/\(lines.filter { $0.signatureTimestamp == -1 }.count)")
    }
}
