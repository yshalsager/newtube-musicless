import Foundation
import JavaScriptCore

public struct SolverError: Error, CustomStringConvertible, Sendable {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// Answers to one answer's challenges, keyed by the challenge string.
public struct ChallengeSolutions: Sendable, Equatable {
    public var n: [String: String] = [:]
    public var sig: [String: String] = [:]
}

/// YouTube's signature (`s`) and throttling (`n`) challenges, solved by the same yt-dlp EJS bundle
/// MediaServiceCore runs in V8 (US-016), here in JavaScriptCore on one serial queue (a `JSContext`
/// is single-threaded). Like Android's `JsRuntimeChalBaseJCP`: the solver library and core are
/// evaluated once per context; a player's first solve hands `jsc` the whole player JS and keeps the
/// preprocessed player it returns (on disk, per player id), later solves hand it the preprocessed
/// one; solved values are remembered in memory.
public actor ChallengeSolver {
    private let queue = DispatchSerialQueue(label: "Musicless-JSC", qos: .userInitiated)
    public nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let cacheDirectory: URL?
    private let log: @Sendable (String) -> Void
    private var context: JSContext?
    private var memo: [String: String] = [:]  // "<player>|n|<challenge>" -> answer

    /// - Parameter cacheDirectory: where preprocessed players persist (Caches in the app); nil keeps
    ///   them out of disk.
    public init(cacheDirectory: URL?, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.cacheDirectory = cacheDirectory
        self.log = log
    }

    /// Solves `n` and `sig` challenges with player `playerID`. `player` loads the raw player JS and is
    /// only called when no preprocessed copy is cached.
    public func solve(playerID: String, n: [String], sig: [String],
                      player: @Sendable () async throws -> String) async throws -> ChallengeSolutions {
        var solutions = ChallengeSolutions()
        let nWanted = Array(Set(n)).sorted(), sigWanted = Array(Set(sig)).sorted()
        let nMissing = nWanted.filter { memo["\(playerID)|n|\($0)"] == nil }
        let sigMissing = sigWanted.filter { memo["\(playerID)|sig|\($0)"] == nil }
        if !nMissing.isEmpty || !sigMissing.isEmpty {
            try await run(playerID: playerID, n: nMissing, sig: sigMissing, player: player)
        }
        for challenge in nWanted { solutions.n[challenge] = memo["\(playerID)|n|\(challenge)"] }
        for challenge in sigWanted { solutions.sig[challenge] = memo["\(playerID)|sig|\(challenge)"] }
        return solutions
    }

    /// Takes the cold cost off the first ciphered video (Android's `MemoWarmup`): a player not yet
    /// preprocessed is preprocessed now (≈ 1.7 s on the A15, once per player version); otherwise only
    /// the context is built.
    public func warm(playerID: String, player: @Sendable () async throws -> String) async throws {
        if cachedPreprocessed(playerID) != nil {
            _ = try makeContext()
            return
        }
        try await run(playerID: playerID, n: ["warmupwarmupwarm"], sig: [], player: player)
    }

    /// Drops the context (memory warning); the next solve rebuilds it from the preprocessed player.
    public func release() {
        context = nil
    }

    // MARK: Running jsc

    private func run(playerID: String, n: [String], sig: [String], player: @Sendable () async throws -> String) async throws {
        var requests: [[String: Any]] = []
        if !n.isEmpty { requests.append(["type": "n", "challenges": n]) }
        if !sig.isEmpty { requests.append(["type": "sig", "challenges": sig]) }

        var input: [String: Any]
        let preprocessed = cachedPreprocessed(playerID)
        if let preprocessed {
            input = ["type": "preprocessed", "preprocessed_player": preprocessed, "requests": requests]
        } else {
            let raw = try await player()
            input = ["type": "player", "player": raw, "requests": requests, "output_preprocessed": true]
        }

        let initStart = ContinuousClock.now
        let context = try makeContext()
        let initMs = Self.milliseconds(since: initStart)
        let solveStart = ContinuousClock.now
        context.exception = nil
        context.setObject(input, forKeyedSubscript: "__musiclessInput" as NSString)
        let value = context.evaluateScript("JSON.stringify(jsc(__musiclessInput))")
        context.setObject(nil, forKeyedSubscript: "__musiclessInput" as NSString)
        if let exception = context.exception {
            throw SolverError("jsc threw: \(exception.toString() ?? "?")")
        }
        guard let text = value?.toString(), let data = text.data(using: .utf8),
              let output = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SolverError("unparsable solver output")
        }
        if output["type"] as? String == "error" { throw SolverError("solver error: \(output["error"] ?? "?")") }
        guard let responses = output["responses"] as? [[String: Any]], responses.count == requests.count else {
            throw SolverError("solver answered \((output["responses"] as? [Any])?.count ?? 0) of \(requests.count) requests")
        }
        for (request, response) in zip(requests, responses) {
            let type = request["type"] as! String
            guard response["type"] as? String == "result", let answers = response["data"] as? [String: String] else {
                log("solver \(type) failed: \(response["error"] ?? "?")")
                continue
            }
            for (challenge, answer) in answers { memo["\(playerID)|\(type)|\(challenge)"] = answer }
        }
        if preprocessed == nil, let fresh = output["preprocessed_player"] as? String { store(fresh, playerID: playerID) }
        log("solver player=\(playerID) source=\(preprocessed == nil ? "raw" : "preprocessed") n=\(n.count) sig=\(sig.count) "
            + "initMs=\(initMs) solveMs=\(Self.milliseconds(since: solveStart))")
    }

    /// The solver library and core, evaluated once per context.
    private func makeContext() throws -> JSContext {
        if let context { return context }
        guard let fresh = JSContext() else { throw SolverError("no JSContext") }
        fresh.name = "Musicless challenge solver"
        for name in ["polyfill", "meriyah-6.1.4.min", "astring-1.9.0.min", "yt.solver.core"] {
            guard let url = Bundle.module.url(forResource: name, withExtension: "js", subdirectory: "JS/nsigsolver"),
                  let script = try? String(contentsOf: url, encoding: .utf8) else {
                throw SolverError("missing \(name).js")
            }
            fresh.evaluateScript(script, withSourceURL: url)
            if let exception = fresh.exception { throw SolverError("\(name).js threw: \(exception.toString() ?? "?")") }
        }
        guard fresh.objectForKeyedSubscript("jsc")?.isObject == true else { throw SolverError("jsc is not defined") }
        context = fresh
        return fresh
    }

    // MARK: Preprocessed players

    private func url(_ playerID: String) -> URL? {
        cacheDirectory?.appending(path: "\(playerID).preprocessed.js")
    }

    private func cachedPreprocessed(_ playerID: String) -> String? {
        url(playerID).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    private func store(_ preprocessed: String, playerID: String) {
        guard let url = url(playerID) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? preprocessed.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
        Int((ContinuousClock.now - start) / .milliseconds(1))
    }
}

/// The player JS by URL, cached on disk per player id (US-016).
public actor PlayerScripts {
    private let transport: InnerTubeTransport
    private let directory: URL?
    private var inFlight: [String: Task<String, Error>] = [:]

    public init(transport: InnerTubeTransport, directory: URL?) {
        self.transport = transport
        self.directory = directory
    }

    public func script(url: String) async throws -> String {
        let id = VisitorIdentity.playerID(url)
        let file = directory?.appending(path: "\(id).js")
        if let file, let cached = try? String(contentsOf: file, encoding: .utf8) { return cached }
        if let task = inFlight[url] { return try await task.value }
        let transport = transport
        let task = Task {
            guard let address = URL(string: url) else { throw SolverError("bad player URL") }
            let answer = try await transport.send(URLRequest(url: address, timeoutInterval: 20), label: "player-js")
            guard answer.status == 200, let text = String(data: answer.data, encoding: .utf8) else {
                throw SolverError("player JS HTTP \(answer.status)")
            }
            return text
        }
        inFlight[url] = task
        defer { inFlight[url] = nil }
        let text = try await task.value
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: file, atomically: true, encoding: .utf8)
        }
        return text
    }
}

/// Opens an answer's ciphered formats (US-016): every format's `n` and `signatureCipher` `s` are
/// solved in one bulk call with the player whose `signatureTimestamp` the request sent, then the URL
/// gets `n` replaced and the signature appended (MediaServiceCore `VideoInfoServiceBase.decipherFormats`,
/// `VideoUrlHolder`). An answer with nothing to solve (VISIONOS, ANDROID_VR) is returned as it is.
public struct CipherResolver: Sendable {
    public let solver: ChallengeSolver
    public let scripts: PlayerScripts

    public init(solver: ChallengeSolver, scripts: PlayerScripts) {
        self.solver = solver
        self.scripts = scripts
    }

    /// Preprocesses `playerURL`'s player ahead of the first ciphered answer (see `ChallengeSolver.warm`).
    public func warm(playerURL: String) async throws {
        let scripts = scripts
        try await solver.warm(playerID: VisitorIdentity.playerID(playerURL)) { try await scripts.script(url: playerURL) }
    }

    public func resolve(_ answer: PlayerAnswer, playerURL: String?) async throws -> PlayerAnswer {
        let pieces = answer.adaptiveFormats.map(Self.pieces)
        let n = pieces.compactMap { $0?.n }, sig = pieces.compactMap { $0?.s }
        guard !n.isEmpty || !sig.isEmpty else { return answer }
        guard let playerURL else { throw SolverError("no player URL to solve with") }
        let scripts = scripts
        let solutions = try await solver.solve(playerID: VisitorIdentity.playerID(playerURL), n: n, sig: sig) {
            try await scripts.script(url: playerURL)
        }
        var opened = answer
        for index in opened.adaptiveFormats.indices {
            guard let piece = pieces[index] else { continue }
            opened.adaptiveFormats[index].url = Self.rewrite(piece, solutions: solutions)
            if opened.adaptiveFormats[index].url != nil { opened.adaptiveFormats[index].signatureCipher = nil }
        }
        return opened
    }

    /// A format's base URL, its `n` and, if ciphered, its `s` and signature parameter name.
    struct Pieces: Equatable {
        var url: String
        var n: String?
        var s: String?
        var sp: String
    }

    static func pieces(_ format: PlayerAnswer.Format) -> Pieces? {
        var url = format.url, s: String?, sp = "sig"
        if url == nil, let cipher = format.signatureCipher {
            let items = URLComponents(string: "?" + cipher)?.queryItems ?? []
            url = items.first { $0.name == "url" }?.value
            s = items.first { $0.name == "s" }?.value
            sp = items.first { $0.name == "sp" }?.value ?? "sig"
        }
        guard let url else { return nil }
        let n = URLComponents(string: url)?.queryItems?.first { $0.name == "n" }?.value
        return Pieces(url: url, n: n, s: s, sp: sp)
    }

    /// The URL with `n` replaced and `<sp>=<signature>` set, other parameters byte for byte. Nil when
    /// a needed answer is missing (the format stays unplayable rather than throttled or refused).
    static func rewrite(_ pieces: Pieces, solutions: ChallengeSolutions) -> String? {
        guard var components = URLComponents(string: pieces.url) else { return nil }
        var items = components.percentEncodedQueryItems ?? []
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
        if let n = pieces.n {
            guard let solved = solutions.n[n], let encoded = solved.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            items = items.map { $0.name == "n" ? URLQueryItem(name: "n", value: encoded) : $0 }
        }
        if let s = pieces.s {
            guard let solved = solutions.sig[s], let encoded = solved.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            items.removeAll { $0.name == pieces.sp }
            items.append(URLQueryItem(name: pieces.sp, value: encoded))
        }
        components.percentEncodedQueryItems = items
        return components.string
    }
}
