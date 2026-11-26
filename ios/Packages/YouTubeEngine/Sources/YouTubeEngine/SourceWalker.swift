import Foundation

/// One `/player` attempt as the walk sees it.
public enum WalkAttempt: Sendable {
    case answer(PlayerAnswer)
    /// No HTTP response at all (a timeout or a dead link): counts towards transport-down.
    case noResponse
    /// A response that could not be used (HTTP error, unparsable body): no evidence either way.
    case failed(String)

    var answer: PlayerAnswer? {
        if case .answer(let answer) = self { return answer }
        return nil
    }
}

/// What a walk settled on (Android's `firstPlayable` return value, plus what it did).
public struct WalkResult: Sendable {
    /// The winner, or the verdict to show; nil when nothing was established (budget, transport down).
    public var answer: PlayerAnswer?
    /// The source of `answer`.
    public var client: ClientProfile?
    /// A playable delivery (VOD, or live with HLS/DASH).
    public var playable: Bool
    /// Every source asked, in order.
    public var asked: [ClientProfile]
    /// This walk tripped the bot-check circuit.
    public var botCheckTripped = false
    /// Answered from the bot-check circuit without a request.
    public var fromCircuit = false
    /// The decision lines, in Android's wording (`anon-tizen next after=…`, `age-gate-settled …`).
    public var markers: [String] = []
}

/// The phone's `/player` walk, a port of MediaServiceCore's `VideoInfoService.firstPlayable` for the
/// signed-out lane (US-015; LANES §2): `SourcePlanner`'s order, then per answer:
/// - served: win (a live answer without DASH is held and only the live-DASH source asked after it);
/// - content refused (UNPLAYABLE, anonymous, non-web, no live signal, not terminal): TV_TIZEN, without
///   the account, is admitted next, once, on the short budget;
/// - age gate: walk on until every source that can serve one has answered (the age-gate stop);
/// - terminal: settles on consensus (iOS: 3 sources over both identities, D46);
/// - bot challenge: held while an unchallenged source remains, discarded once something plays; a
///   repeated sign-in request trips the circuit only when a second video repeats it within 10 min;
/// - no response: transport-down after 2 in a row; 45 s per walk, 1.5 s minimum per attempt.
/// Between walks it keeps the bot-check circuit (15 min, one probe a minute, only after a walk that
/// reached the end) and the anonymous-challenge memory (15 min). Recovery state (suspects, refusals,
/// walls) arrives through `SourcePlanner.Context` (US-017).
public actor SourceWalker {
    public typealias Ask = @Sendable (ClientProfile, Duration) async -> WalkAttempt

    public static let walkBudget: Duration = .seconds(45)
    static let accountRouteBudget: Duration = .seconds(15)
    static let minAttemptBudget: Duration = .milliseconds(1_500)
    static let transportDownStreak = 2
    static let circuitCooldown: Duration = .seconds(15 * 60)
    static let circuitProbeInterval: Duration = .seconds(60)
    static let repeatedLoginConfirm: Duration = .seconds(10 * 60)
    static let anonChallengeCooldown: Duration = .seconds(15 * 60)
    static let anonChallengeMinHits = 2
    static let signalRepeatedLogin = "repeated-login"

    private let now: @Sendable () -> ContinuousClock.Instant
    private let network: @Sendable () async -> String?
    private let log: @Sendable (String) -> Void

    // The bot-check circuit (VideoInfoService.tripBotCheckCircuit).
    private struct Circuit {
        var result: PlayerAnswer
        var client: ClientProfile
        var until: ContinuousClock.Instant
        var ringExhausted: Bool
        var nextProbe: ContinuousClock.Instant
        var network: String?
    }
    private var circuit: Circuit?
    private var probePending = false
    /// RecentRefusals: per video, the sources that refused it lately (30 min), dropped on a serve.
    private var refusals: [String: [ClientProfile: (at: ContinuousClock.Instant, kids: Bool)]] = [:]
    private var refusalOrder: [String] = []
    static let refusalTTL: Duration = .seconds(30 * 60)
    static let refusalVideos = 16
    /// BotWallBook's route record: the account route failed (a media 403) for a video on a network;
    /// a second video within 30 min benches it for the network. Persisted (Android keeps it within a
    /// boot), on the wall clock.
    private struct RouteRecord: Codable {
        var videos: [String: Date] = [:]
        var until: Date?
    }
    private var routeFailures: [String: RouteRecord] = [:]
    static let routeFailureTTL: TimeInterval = 30 * 60
    private let date: @Sendable () -> Date
    private let routeStore: URL?
    private var repeatedLogin: (video: String, at: ContinuousClock.Instant)?
    private var anonChallenge: (network: String, until: ContinuousClock.Instant)?

    /// - Parameters:
    ///   - now: the clock (tests replay a device's timing).
    ///   - network: the current network's signature (`NetworkWatcher`); a change clears the circuit.
    ///   - date: the wall clock, for the persisted route record.
    ///   - routeStore: where the account route's record persists; nil keeps it in memory.
    public init(now: @escaping @Sendable () -> ContinuousClock.Instant = { .now },
                date: @escaping @Sendable () -> Date = { Date() },
                network: @escaping @Sendable () async -> String? = { nil },
                routeStore: URL? = nil,
                log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.now = now
        self.date = date
        self.network = network
        self.routeStore = routeStore
        self.log = log
        if let routeStore, let data = try? Data(contentsOf: routeStore),
           let decoded = try? JSONDecoder().decode([String: RouteRecord].self, from: data) {
            routeFailures = decoded
        }
    }

    /// Walks the sources for `videoID`. `context.anonChallenged` is filled in from memory.
    public func walk(videoID: String, context base: SourcePlanner.Context, ask: Ask) async -> WalkResult {
        let networkKey = await network()
        if let answered = activeCircuit(videoID: videoID, network: networkKey) { return answered }

        var context = base
        context.anonChallenged = isAnonChallenged(network: networkKey)
        let lane = context.lane
        let time = now()
        if isRouteFailed(network: networkKey, videoID: videoID) { context.accountRouteBenched = true }
        // A recovery walk asks what refused this video moments ago after everything else, and a
        // made-for-kids refusal puts the sources that never serve one behind the suspect.
        if let suspect = context.recoverySuspect {
            context.recoveryRefused = recentRefusals(videoID: videoID, at: time)
            context.recoveryKidsRefused = SourcePlanner.servesMadeForKids(suspect) && hasMadeForKidsRefusal(videoID: videoID, at: time)
        }
        var order = SourcePlanner.order(context)
        log("player-ring plan video=\(videoID) lane=\(lane.rawValue)"
            + (context.recoverySuspect.map { " suspect=\($0.id)" } ?? "")
            + (context.recoveryKidsRefused ? " made-for-kids" : "") + (context.vodVrLate ? " vod-vr-late" : "")
            + (context.anonChallenged ? " anon-challenged" : "") + (context.accountRouteBenched ? " account-route=benched" : "")
            + (context.benched.isEmpty ? "" : " walled=\(context.benched.map(\.id).sorted())")
            + (context.refreshed.isEmpty ? "" : " refreshed=\(context.refreshed.map(\.id).sorted())")
            + (context.recoveryRefused.isEmpty ? "" : " refused=\(context.recoveryRefused.map(\.id).sorted())")
            + " order=\(order.map(\.id))")

        var result = WalkResult(answer: nil, client: nil, playable: false, asked: [])
        func mark(_ line: String) {
            result.markers.append(line)
            log("player-ring \(line) video=\(videoID)")
        }

        var firstUnplayable: (PlayerAnswer, ClientProfile)?
        var firstLoginRequired: PlayerAnswer?
        var signInReasons = Set<String>()
        var liveWithoutDash: (PlayerAnswer, ClientProfile)?
        var botCheck = BotCheckWalkState()
        var consensus = UnplayableConsensus()
        var attempted = Set<ClientProfile>()
        // TV_TIZEN planned third signed out (vod-vr-late) is the same anonymous ask: the short budget.
        var anonTizenSpeculative = context.vodVrLate && lane == .signedOut
        var firstAgeGate: (PlayerAnswer, ClientProfile)?
        var refused = Set<ClientProfile>()
        var anonChallengeHits = 0
        var attempt = 0
        let deadline = now() + Self.walkBudget
        var budgetExhausted = false
        var noResponseStreak = 0
        var transportDown = false

        var index = 0
        while index < order.count {
            defer { index += 1 }
            let client = order[index]
            let remaining = deadline - now()
            if attempt > 0 && remaining < Self.minAttemptBudget {
                budgetExhausted = true
                botCheck.cutShort = true
                mark("budget-exhausted attempts=\(attempt) nextClient=\(client.id)")
                break
            }
            // A live answer is held and only a DASH manifest can improve on it.
            if liveWithoutDash != nil && client != SourcePlanner.liveSource { continue }

            attempt += 1
            attempted.insert(client)
            result.asked.append(client)
            if attempt == 1, probePending {
                probePending = false
                circuit?.nextProbe = now() + Self.circuitProbeInterval
            }
            // The refusal rule's TV_TIZEN is a speculative ask: the short budget.
            // With the account (signed in) the account route gets Android's 15 s.
            let budget = anonTizenSpeculative && client == SourcePlanner.accountRoute
                ? min(remaining, .seconds(7))
                : lane == .signedIn && client == SourcePlanner.accountRoute ? min(Self.accountRouteBudget, remaining)
                : min(client.attemptTimeout, remaining)
            let outcome = await ask(client, budget)
            let answer = outcome.answer
            let kind = answer.map(AnswerKind.init)
            let playable = kind == .served || kind == .liveWithoutDash
            log("player-result client=\(client.id) attempt=\(attempt) kind=\(kind?.logValue ?? "\(outcome)")"
                + (answer?.playability.text.map { " reason=\"\($0.prefix(90))\"" } ?? ""))

            if let answer, kind == .contentRefused, !Self.hasLiveSignal(answer), !client.isWebPotRequired {
                botCheck.contentRefusals += 1
            }
            if let answer { noteRecent(videoID: videoID, client: client, answer: answer, kind: kind!, playable: playable) }
            // Signed out, an anonymous content refusal admits TV_TIZEN without the account, once.
            if let answer, SourcePlanner.admitsAccountRouteAfter(lane: lane, client: client), kind == .contentRefused,
               !Self.hasLiveSignal(answer), liveWithoutDash == nil, !attempted.contains(SourcePlanner.accountRoute),
               context.recoverySuspect != SourcePlanner.accountRoute,
               !context.recoveryRefused.contains(SourcePlanner.accountRoute),
               !context.benched.contains(SourcePlanner.accountRoute), !context.accountRouteBenched,
               index + 1 >= order.count || order[index + 1] != SourcePlanner.accountRoute {
                order.insert(SourcePlanner.accountRoute, at: index + 1)
                anonTizenSpeculative = true
                mark("anon-tizen next after=\(client.id) attempt=\(attempt) reason=unplayable")
            }

            // A dead link is not a bad source: two silent attempts in a row stop the walk.
            if case .noResponse = outcome {
                noResponseStreak += 1
                if noResponseStreak >= Self.transportDownStreak {
                    transportDown = true
                    botCheck.cutShort = true
                    mark("transport-down attempts=\(attempt) lastClient=\(client.id)")
                    break
                }
            } else {
                noResponseStreak = 0
            }

            if let answer, answer.playability.status == "LOGIN_REQUIRED", kind != .ageGate, kind != .botChallenge {
                signInReasons.insert(AnswerKind.normalize(answer.playability.text ?? ""))
            }
            if let answer {
                let repeated = firstLoginRequired.map {
                    kind != .ageGate && Self.isRepeatedLoginRequired($0, answer)
                } ?? false
                if kind == .botChallenge || repeated {
                    let signal = kind == .botChallenge ? "explicit" : Self.signalRepeatedLogin
                    if signal == "explicit" {
                        anonChallengeHits += 1
                        noteAnonymousChallenge(hits: anonChallengeHits, network: networkKey, mark: mark)
                    }
                    if botCheck.record(answer, client: client, signal: signal, order: order, index: index) {
                        mark("bot-check walk-on client=\(client.id) signal=\(signal) attempt=\(attempt)")
                    } else if isChallengeConfirmed(signal: signal, videoID: videoID, reasonsAgree: signInReasons.count <= 1,
                                                   mark: mark) {
                        trip(answer, client: client, signal: signal, ringExhausted: !botCheck.cutShort, network: networkKey, mark: mark)
                        result.answer = answer
                        result.client = client
                        result.botCheckTripped = true
                        return result
                    }
                }
                if firstLoginRequired == nil, answer.playability.status == "LOGIN_REQUIRED", kind != .ageGate {
                    firstLoginRequired = answer
                }
            }

            // Terminal consensus.
            if liveWithoutDash == nil, let answer {
                let key: String? = if case .terminal(let terminal) = kind { terminal } else { nil }
                if consensus.note(client, status: answer.playability.status, key: kind == .botChallenge ? nil : key) {
                    mark("definitive-unplayable clients=\(consensus.clients.map(\.id).joined(separator: ",")) attempts=\(attempt)")
                    result.answer = answer
                    result.client = client
                    return result
                }
            }

            // The age-gate stop: once every source that can serve an age gate has answered.
            if liveWithoutDash == nil, let answer, !playable {
                if firstAgeGate == nil, kind == .ageGate { firstAgeGate = (answer, client) }
                refused.insert(client)
                if SourcePlanner.isAgeGateSettled(lane: lane, ageGated: firstAgeGate != nil, refused: refused,
                                                  attempted: attempted, remaining: Array(order[(index + 1)...])) {
                    mark("age-gate-settled refused=\(refused.map(\.id).sorted()) attempts=\(attempt)")
                    result.answer = firstAgeGate?.0
                    result.client = firstAgeGate?.1
                    return result
                }
            }

            if let answer, playable {
                botCheck.discard()
                if kind == .liveWithoutDash {
                    if liveWithoutDash == nil {
                        liveWithoutDash = (answer, client)
                        mark("live-no-dash client=\(client.id)")
                    }
                } else {
                    if answer.isLive { mark("winner-kept reason=live client=\(client.id)") }
                    result.answer = answer
                    result.client = client
                    result.playable = true
                    return result
                }
            }
            if firstUnplayable == nil, let answer { firstUnplayable = (answer, client) }
        }

        // A challenge the walk carried on past is its verdict if nothing played; a deadline or a
        // dead link established nothing (null, "could not load"), unless a live answer is held.
        if var challenge = botCheck.finish(transportDown: transportDown) {
            if !isChallengeConfirmed(signal: challenge.signal, videoID: videoID, reasonsAgree: signInReasons.count <= 1, mark: mark) {
                challenge.confirmed = false
            }
            if challenge.confirmed {
                trip(challenge.answer, client: challenge.client, signal: challenge.signal, ringExhausted: !botCheck.cutShort,
                     network: networkKey, mark: mark)
                result.answer = challenge.answer
                result.client = challenge.client
                result.botCheckTripped = true
                return result
            }
        }
        if (budgetExhausted || transportDown) && liveWithoutDash == nil { return result }
        if let (answer, client) = liveWithoutDash {
            mark("live-no-dash exhausted attempts=\(attempt)")
            result.answer = answer
            result.client = client
            result.playable = true
            return result
        }
        result.answer = firstUnplayable?.0
        result.client = firstUnplayable?.1
        return result
    }

    // MARK: Recovery memory

    /// The player's media for `videoID` got a 403 from `client`'s links. For the account route, its
    /// route record (BotWallBook.noteRouteFailed): benched for that video; for the network once a
    /// second video fails within 30 min.
    public func noteMediaRefused(videoID: String, client: ClientProfile) async {
        guard client == SourcePlanner.accountRoute, let network = await network() else { return }
        let time = date()
        var record = routeFailures[network] ?? RouteRecord()
        record.videos = record.videos.filter { time < $0.value }
        let otherVideo = record.videos.keys.contains { $0 != videoID }
        record.videos[videoID] = time.addingTimeInterval(Self.routeFailureTTL)
        if otherVideo { record.until = time.addingTimeInterval(Self.routeFailureTTL) }
        routeFailures[network] = record
        if let routeStore, let data = try? JSONEncoder().encode(routeFailures) {
            try? FileManager.default.createDirectory(at: routeStore.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: routeStore, options: .atomic)
        }
        log("account-route failed reason=media-403 video=\(videoID) scope=\(otherVideo ? "network" : "video")")
    }

    private func isRouteFailed(network: String?, videoID: String) -> Bool {
        guard let network, let record = routeFailures[network] else { return false }
        let time = date()
        if let until = record.until, time < until { return true }
        return record.videos[videoID].map { time < $0 } ?? false
    }

    /// RecentRefusals.noteRefused / noteServed.
    private func noteRecent(videoID: String, client: ClientProfile, answer: PlayerAnswer, kind: AnswerKind, playable: Bool) {
        if playable {
            refusals[videoID]?[client] = nil
            return
        }
        guard Self.isRefusalOfTheVideo(client: client, answer: answer, kind: kind) else { return }
        let kids = SourcePlanner.refusesMadeForKids(client) && kind == .contentRefused && !Self.hasLiveSignal(answer)
        refusals[videoID, default: [:]][client] = (now(), kids)
        refusalOrder.removeAll { $0 == videoID }
        refusalOrder.append(videoID)
        while refusalOrder.count > Self.refusalVideos { refusals[refusalOrder.removeFirst()] = nil }
    }

    private func recentRefusals(videoID: String, at time: ContinuousClock.Instant) -> Set<ClientProfile> {
        Set((refusals[videoID] ?? [:]).filter { time - $0.value.at < Self.refusalTTL }.keys)
    }

    private func hasMadeForKidsRefusal(videoID: String, at time: ContinuousClock.Instant) -> Bool {
        (refusals[videoID] ?? [:]).values.contains { $0.kids && time - $0.at < Self.refusalTTL }
    }

    /// A refusal about the video for this identity (which a recovery would hear again): a content
    /// refusal, a sign-in request or an age gate; not a bot check, a live signal or WEB_EMBED's 152.
    static func isRefusalOfTheVideo(client: ClientProfile, answer: PlayerAnswer, kind: AnswerKind) -> Bool {
        let status = answer.playability.status
        let aboutTheVideo = status == "UNPLAYABLE" || status == "LOGIN_REQUIRED" || kind == .ageGate
        return aboutTheVideo && kind != .served && kind != .liveWithoutDash && kind != .botChallenge && !hasLiveSignal(answer)
            && !(client == .webEmbed && answer.playability.text?.contains("152") == true)
    }

    // MARK: Cross-walk memory

    /// The circuit answers an open without a request while armed, except: a different network
    /// clears it; a walk that didn't reach the end never earns suppression; one probe a minute.
    private func activeCircuit(videoID: String, network: String?) -> WalkResult? {
        guard let armed = circuit else { return nil }
        let time = now()
        if time >= armed.until {
            circuit = nil
            return nil
        }
        if let armedOn = armed.network, let network, armedOn != network {
            log("bot-check cleared reason=network-change video=\(videoID)")
            circuit = nil
            return nil
        }
        guard armed.ringExhausted else {
            log("bot-check bypass=partial-walk video=\(videoID)")
            return nil
        }
        if time >= armed.nextProbe {
            probePending = true
            log("bot-check probe video=\(videoID)")
            return nil
        }
        log("bot-check cooldown video=\(videoID)")
        return WalkResult(answer: armed.result, client: armed.client, playable: false, asked: [], fromCircuit: true,
                          markers: ["bot-check cooldown"])
    }

    private func trip(_ answer: PlayerAnswer, client: ClientProfile, signal: String, ringExhausted: Bool, network: String?,
                      mark: (String) -> Void) {
        let time = now()
        circuit = Circuit(result: answer, client: client, until: time + Self.circuitCooldown, ringExhausted: ringExhausted,
                          nextProbe: time + Self.circuitProbeInterval, network: network)
        mark("bot-check trip client=\(client.id) signal=\(signal) ringExhausted=\(ringExhausted ? "y" : "n")")
    }

    /// An explicit bot text may trip. A repeated sign-in request is also what a private video
    /// answers: it trips only when the walk's sign-in requests agree and a second video repeats it
    /// within 10 minutes.
    private func isChallengeConfirmed(signal: String, videoID: String, reasonsAgree: Bool, mark: (String) -> Void) -> Bool {
        guard signal == Self.signalRepeatedLogin else { return true }
        guard reasonsAgree else {
            mark("repeated-login unconfirmed reason=sign-in-requests-differ")
            return false
        }
        let time = now()
        let confirmed = repeatedLogin.map { $0.video != videoID && time - $0.at <= Self.repeatedLoginConfirm } ?? false
        let earlier = repeatedLogin?.video
        repeatedLogin = (videoID, time)
        mark(confirmed ? "repeated-login confirmed-by=\(earlier ?? "?")" : "repeated-login unconfirmed reason=one-video")
        return confirmed
    }

    /// Two anonymous identities challenged in one walk: web sources go last for 15 min on this network.
    private func noteAnonymousChallenge(hits: Int, network: String?, mark: (String) -> Void) {
        guard hits >= Self.anonChallengeMinHits, let network else { return }
        let time = now()
        let fresh = anonChallenge.map { $0.network != network || time >= $0.until } ?? true
        anonChallenge = (network, time + Self.anonChallengeCooldown)
        if fresh { mark("anon-challenged hits=\(hits)") }
    }

    private func isAnonChallenged(network: String?) -> Bool {
        guard let challenge = anonChallenge, now() < challenge.until else { return false }
        guard let network, network == challenge.network else {
            anonChallenge = nil
            return false
        }
        return true
    }

    // MARK: Predicates

    /// Live, live content, or a scheduled start: a refusal of such a video isn't TV_TIZEN's to fix.
    static func hasLiveSignal(_ answer: PlayerAnswer) -> Bool {
        answer.isLive || answer.details?.isLiveContent == true
    }

    /// BotCheckDetector.isRepeatedLoginRequired: two LOGIN_REQUIRED answers with the same normalized text.
    static func isRepeatedLoginRequired(_ first: PlayerAnswer, _ current: PlayerAnswer) -> Bool {
        guard first.playability.status == "LOGIN_REQUIRED", current.playability.status == "LOGIN_REQUIRED",
              let a = first.playability.text, let b = current.playability.text else { return false }
        return AnswerKind.normalize(a) == AnswerKind.normalize(b)
    }
}

/// Walk-scoped bot-check bookkeeping (VideoInfoService.BotCheckWalkState): a challenge to an
/// anonymous request is evidence about the identity, not the video, so it is held while a source
/// that doesn't share it remains, published only if nothing plays.
struct BotCheckWalkState {
    struct Outcome {
        var answer: PlayerAnswer
        var client: ClientProfile
        var signal: String
        var confirmed = true
    }

    private var held: Outcome?
    private var challenged = Set<ClientProfile>()
    var contentRefusals = 0
    /// The walk ended early (budget, dead link): it didn't reach the end of the order.
    var cutShort = false

    /// Records a challenge; true means the walk may carry on past it.
    mutating func record(_ answer: PlayerAnswer, client: ClientProfile, signal: String, order: [ClientProfile],
                         index: Int) -> Bool {
        challenged.insert(client)
        guard Self.hasUnchallengedSource(after: index, in: order) || isLoneChallengeAmidRefusals else { return false }
        if held == nil { held = Outcome(answer: answer, client: client, signal: signal) }
        return true
    }

    /// One source challenged while non-web sources refused the video on its content: the video's
    /// own refusal is the verdict, not a bot check.
    var isLoneChallengeAmidRefusals: Bool { challenged.count == 1 && contentRefusals > 0 }

    mutating func discard() { held = nil }

    func finish(transportDown: Bool) -> Outcome? {
        guard let held, !transportDown, !isLoneChallengeAmidRefusals else { return nil }
        return held
    }

    /// Web sources share the challenged anonymous identity; every other one presents another.
    static func hasUnchallengedSource(after index: Int, in order: [ClientProfile]) -> Bool {
        order.dropFirst(index + 1).contains { !$0.isWebPotRequired }
    }
}

/// When every source says the same terminal thing, the walk has nothing left to find
/// (VideoInfoService.UnplayableConsensus, signed out). Android counts three identities (web session,
/// app visitor, embed page); iOS has two (D46), so it needs the same allowlisted key from three
/// sources over both. ERROR answers with no allowlisted reason are neutral; anything else breaks it.
struct UnplayableConsensus {
    static let minClients = 3
    static let minIdentities = 2

    private var key: String?
    private var broken = false
    private(set) var clients: [ClientProfile] = []
    private var identities = Set<ClientProfile.Identity>()

    mutating func note(_ client: ClientProfile, status: String, key: String?) -> Bool {
        if broken || (key == nil && status == "ERROR") { return !broken && isDefinitive }
        guard let key, self.key == nil || self.key == key else {
            broken = true
            return false
        }
        self.key = key
        if !clients.contains(client) { clients.append(client) }
        identities.insert(client.identity)
        return isDefinitive
    }

    private var isDefinitive: Bool { clients.count >= Self.minClients && identities.count >= Self.minIdentities }
}
