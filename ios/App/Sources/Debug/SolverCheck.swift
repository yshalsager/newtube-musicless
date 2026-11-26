import Foundation
import YouTubeEngine

/// `--solver-check` (US-016): the challenge solver's speed on this phone. With YouTube's current TV
/// player: the download, a cold solve (a fresh JSContext, the raw player, 6 n and 4 sig challenges),
/// a solve from the preprocessed player in another fresh context, and one from the memo. Each run
/// three times; the cache is a temporary directory, so the app's own is untouched.
enum SolverCheck {
    @MainActor
    static func run() async {
        let log: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
        let services = PlaybackServices.shared
        guard let playerURL = try? await services.identity.current().playerURL else { return log("solver-check no player URL") }
        let downloadStart = ContinuousClock.now
        guard let url = URL(string: playerURL),
              let answer = try? await services.transport.send(URLRequest(url: url, timeoutInterval: 20), label: "player-js"),
              let player = String(data: answer.data, encoding: .utf8) else { return log("solver-check download failed") }
        log("solver-check player=\(playerURL.split(separator: "/").dropFirst(3).first ?? "?") bytes=\(answer.data.count) "
            + "downloadMs=\(milliseconds(since: downloadStart))")
        let (n, sig) = challenges()
        for round in 1...3 {
            let cache = URL.temporaryDirectory.appending(path: "solver-check-\(round)")
            try? FileManager.default.removeItem(at: cache)
            do {
                let cold = ChallengeSolver(cacheDirectory: cache, log: log)
                var start = ContinuousClock.now
                let coldAnswers = try await cold.solve(playerID: "check", n: n, sig: sig) { player }
                let coldMs = milliseconds(since: start)
                let warm = ChallengeSolver(cacheDirectory: cache, log: log)
                start = .now
                let warmAnswers = try await warm.solve(playerID: "check", n: n, sig: sig) { player }
                let warmMs = milliseconds(since: start)
                start = .now
                _ = try await warm.solve(playerID: "check", n: n, sig: sig) { player }
                let memoMs = milliseconds(since: start)
                log("solver-check round=\(round) coldMs=\(coldMs) preprocessedMs=\(warmMs) memoMs=\(memoMs) "
                    + "n=\(coldAnswers.n.count)/\(n.count) sig=\(coldAnswers.sig.count)/\(sig.count) same=\(coldAnswers == warmAnswers ? "y" : "n") "
                    + "sample=\(coldAnswers.n[n[0]] ?? "-")")
            } catch {
                log("solver-check round=\(round) failed: \(error)")
            }
            try? FileManager.default.removeItem(at: cache)
        }
        log("solver-check done")
    }

    /// The oracle's challenges (ios/tools/solver-oracle/oracle.mjs): xorshift32 from 20261125.
    static func challenges() -> (n: [String], sig: [String]) {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        var seed: UInt32 = 20_261_125
        func next() -> UInt32 {
            seed ^= seed << 13
            seed ^= seed >> 17
            seed ^= seed << 5
            return seed
        }
        func make(_ length: Int) -> String { String((0..<length).map { _ in alphabet[Int(next() % 64)] }) }
        let n = (0..<6).map { _ in make(16) }
        let sig = (0..<4).map { _ in make(104) }
        return (n, sig)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }
}
