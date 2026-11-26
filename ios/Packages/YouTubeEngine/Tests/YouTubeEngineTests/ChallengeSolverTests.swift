import Foundation
import Testing
@testable import YouTubeEngine

/// US-016: the EJS bundle in JavaScriptCore against the same bundle in V8 (Node), on YouTube's
/// current TV player. `ios/tools/solver_oracle.sh` writes the player and Node's answers to the
/// gitignored ios/.fixtures/solver; the live test skips without them.
@Suite struct ChallengeSolverTests {
    static let fixtures = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../.fixtures/solver").standardizedFileURL

    struct Expected: Decodable {
        let engine: String
        let ms: Int
        let n: [String: String]
        let sig: [String: String]
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: fixtures.appending(path: "expected.json").path)))
    func javaScriptCoreAnswersWhatV8Answers() async throws {
        let expected = try JSONDecoder().decode(Expected.self, from: Data(contentsOf: Self.fixtures.appending(path: "expected.json")))
        let player = try String(contentsOf: Self.fixtures.appending(path: "player.js"), encoding: .utf8)
        let cache = FileManager.default.temporaryDirectory.appending(path: "solver-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let lines = LockedLog()

        // Cold: a new context, the raw player.
        let solver = ChallengeSolver(cacheDirectory: cache, log: { lines.append($0) })
        let start = ContinuousClock.now
        let cold = try await solver.solve(playerID: "fixture", n: Array(expected.n.keys), sig: Array(expected.sig.keys)) { player }
        let coldMs = Int((ContinuousClock.now - start) / .milliseconds(1))
        #expect(cold.n == expected.n, "n: JavaScriptCore and \(expected.engine) disagree")
        #expect(cold.sig == expected.sig, "sig: JavaScriptCore and \(expected.engine) disagree")

        // Warm: a new context from the cached preprocessed player; the raw one must not be asked for.
        let warmSolver = ChallengeSolver(cacheDirectory: cache, log: { lines.append($0) })
        let warmStart = ContinuousClock.now
        let warm = try await warmSolver.solve(playerID: "fixture", n: Array(expected.n.keys), sig: []) {
            Issue.record("the preprocessed player should have been used")
            return player
        }
        let warmMs = Int((ContinuousClock.now - warmStart) / .milliseconds(1))
        #expect(warm.n == expected.n)

        // Memo: already solved values need no JavaScript at all.
        let memoStart = ContinuousClock.now
        _ = try await warmSolver.solve(playerID: "fixture", n: Array(expected.n.keys), sig: []) { player }
        let memoMs = Int((ContinuousClock.now - memoStart) / .milliseconds(1))
        print("JavaScriptCore solve (Mac): cold \(coldMs) ms, preprocessed \(warmMs) ms, memo \(memoMs) ms; V8 cold \(expected.ms) ms")
        print(lines.text)
    }

    // MARK: URL rewriting

    static func format(_ itag: Int, _ mime: String) throws -> PlayerAnswer.Format {
        let json = #"{"playabilityStatus":{"status":"OK"},"streamingData":{"adaptiveFormats":["#
            + PlayerAnswerTests.format(itag, mime, bitrate: 1) + "]}}"
        return try #require(try PlayerAnswer(json: Data(json.utf8)).adaptiveFormats.first)
    }

    @Test func aCipheredFormatGetsItsSignatureAndNewN() throws {
        let cipher = "s=SIGCHALLENGE&sp=sig&url=https%3A%2F%2Frr1---sn-x.googlevideo.com%2Fvideoplayback%3Fexpire%3D1%26mn%3Dsn-a%252Csn-b%26n%3DNCHALLENGE%26itag%3D140"
        var format = try Self.format(140, #"audio/mp4; codecs="mp4a.40.2""#)
        format.url = nil
        format.signatureCipher = cipher
        let pieces = try #require(CipherResolver.pieces(format))
        #expect(pieces.s == "SIGCHALLENGE" && pieces.n == "NCHALLENGE" && pieces.sp == "sig")
        let solutions = ChallengeSolutions(n: ["NCHALLENGE": "solved-n"], sig: ["SIGCHALLENGE": "AB=C/D+"])
        let url = try #require(CipherResolver.rewrite(pieces, solutions: solutions))
        #expect(url.contains("n=solved-n"))
        #expect(url.contains("sig=AB%3DC/D%2B"), "the signature is query-encoded (\(url))")
        #expect(url.contains("mn=sn-a%2Csn-b"), "other parameters keep their encoding byte for byte (\(url))")
        #expect(!url.contains("NCHALLENGE"))
    }

    @Test func aMissingAnswerLeavesTheFormatUnplayableAndPlainURLsPassThrough() throws {
        let plain = CipherResolver.Pieces(url: "https://x.googlevideo.com/videoplayback?itag=140&n=ABC", n: "ABC", s: nil, sp: "sig")
        #expect(CipherResolver.rewrite(plain, solutions: ChallengeSolutions()) == nil)
        var format = try Self.format(140, #"audio/mp4; codecs="mp4a.40.2""#)
        format.url = "https://x.googlevideo.com/videoplayback?itag=140&expire=1"
        let pieces = try #require(CipherResolver.pieces(format))
        #expect(pieces.n == nil && pieces.s == nil, "VISIONOS-style URLs have nothing to solve")
    }
}

final class LockedLog: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
}
