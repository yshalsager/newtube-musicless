import Foundation
import YouTubeEngine

/// Watch history, signed in (US-022; LANES §3, VideoStateController.updateHistory): when playback
/// starts, pauses, ends or stops, the stats pings for the position (at least 3 s; the end counts as
/// fully watched). Their tracking comes from an answer asked with the account: the account
/// route's when it won, otherwise one TV /player with the account, sent once per video.
actor HistoryReporter {
    private let transport: InnerTubeTransport
    private let sources: PlayerSources
    private let tokens: AccountTokens
    private var history = WatchHistory()
    private var tracking: [String: WatchHistory.Tracking] = [:]
    private var trackingTries: [String: Int] = [:]

    init(transport: InnerTubeTransport, sources: PlayerSources, tokens: AccountTokens) {
        self.transport = transport
        self.sources = sources
        self.tokens = tokens
    }

    /// The winner's tracking, when the account route served with the account.
    func noteAccountAnswer(videoID: String, tracking: WatchHistory.Tracking?) {
        if let tracking { self.tracking[videoID] = tracking }
    }

    func report(videoID: String, position: Double, length: Double, event: String) async {
        guard let authorization = await tokens.authorization(), length > 0 else { return }
        if tracking[videoID] == nil {
            // Up to three tries per video (LANES §3: one failed answer used to lose the history).
            guard trackingTries[videoID, default: 0] < 3 else { return }
            trackingTries[videoID, default: 0] += 1
            tracking[videoID] = await sources.historyTracking(videoID: videoID, authorization: authorization)
        }
        guard let tracking = tracking[videoID] else { return }
        let pings = history.pings(videoID: videoID, position: max(position, 3), length: length, tracking: tracking)
        var statuses: [String] = []
        for url in pings {
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            request.setValue(ClientProfile.tv.userAgent, forHTTPHeaderField: "User-Agent")
            let status = (try? await transport.send(request, label: "history"))?.status
            statuses.append(status.map(String.init) ?? "error")
        }
        AppLog.netPath.info("history-ping video=\(videoID) event=\(event) at=\(Int(position)) len=\(Int(length)) "
                            + "pings=\(pings.map { $0.lastPathComponent }) status=\(statuses)")
    }
}
