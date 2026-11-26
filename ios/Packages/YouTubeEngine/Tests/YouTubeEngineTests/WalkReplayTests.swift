import Foundation
import os
import Testing
@testable import YouTubeEngine

/// US-015: the iOS walk against the answers YouTube gave Android devices (Fixtures/walks, Android's
/// `VideoInfoReplayTest` fixture). Each signed-out case runs as one simulated device: its walks in
/// order on one `SourceWalker` (a new one per app process), the clock advancing as the device's
/// did, every answer rebuilt as /player JSON and parsed by `PlayerAnswer`. Each walk must ask the
/// sources the device asked, in the same order, and settle the same way (playable or not, same
/// source, the bot-check circuit tripped or not).
///
/// iOS differs on purpose in two places, and only there:
/// - it doesn't ask MWEB, WEB and WEB_SAFARI (PRD §4.4), so they're dropped from the device's list;
/// - terminal consensus counts two identities, not three (D46): `iosChanges` names each walk it
///   shortens, with the reason.
/// A walk asking a source the device never asked fails ("needs a device answer"). A media failure
/// between walks is replayed as the app's recovery does it (US-017): the walk's route record and the
/// wall book hear the 403 with the device's stream positions, and the next walk of that video is a
/// recovery walk with the device's suspect. Where Android's current code asks differently from the
/// device's old build, the fixture's `expect.changed` is what's checked. Signed-in cases (US-022)
/// are not replayed yet.
@Suite struct WalkReplayTests {
    // MARK: Fixture

    struct Fixture: Decodable { let cases: [Case] }
    struct Case: Decodable {
        let name: String
        let exclude: String?
        let opens: [Open]
    }
    struct Open: Decodable {
        let lane: String
        let atMs: Int
        let newProcess: Bool?
        let steps: [Step]
    }
    struct Step: Decodable {
        let type: String
        let atMs: Int
        let video: String
        let suspect: String?
        let answers: [Answer]?
        let expect: Expect?
        let media403: Media403?
    }
    struct Media403: Decodable {
        let forbiddenStartMs: Int64
        let lowestServedStartMs: Int64
        let highestServedStartMs: Int64
    }
    struct Answer: Decodable {
        let client: String
        let parsed: Bool
        let status: String?
        let reason: String?
        let exact: Bool?
        let exactReason: String?
        let exactSubreason: String?
        let playable: Bool
        let adaptive: Int
        let usableAdaptive: Int
        let dash: Bool
        let hls: Bool
        let sabr: Bool
        let live: Bool
        let liveContent: Bool
        let ageGate: Bool
    }
    struct Expect: Decodable {
        let asked: [String]
        let result: String
        let client: String?
        let botCheckTrip: Bool?
        let changed: Changed?
    }
    struct Changed: Decodable {
        let asked: [String]
        let why: String
    }

    static let fixture: Fixture = {
        let url = Bundle.module.url(forResource: "device_walks", withExtension: "json", subdirectory: "Fixtures/walks")!
        return try! JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }()

    static let skippedClients: Set<String> = ["MWEB", "WEB", "WEB_SAFARI"]

    /// Walks iOS settles differently, keyed "case#walk": the sources iOS asks, the result's source
    /// (nil: the walk goes past what the device answered, so only `asked` as a prefix is checked), why.
    static let iosChanges: [String: (asked: [String], client: String?, why: String)] = [
        "removed-for-violation#0": (["VISIONOS", "WEB_EMBED", "ANDROID_VR"], "ANDROID_VR",
                                    "consensus over two identities settles at the third source (D46); Android's needs IOS's"),
        "private-ordinary-members-one-process#2": (["VISIONOS", "WEB_EMBED", "ANDROID_VR"], "ANDROID_VR",
                                                   "members only: consensus over two identities at the third source (D46)"),
        "lte-bot-wall-after-a-kids-403#5": (["WEB_EMBED"], nil, sabrHLS),
        "emu-kids-recovery-after-a-bench#1": (["WEB_EMBED"], nil, sabrHLS),
        "emu-kids-recovery-after-a-bench#3": (["WEB_EMBED"], nil, sabrHLS),
        "emu-kids-recovery-after-a-bench#4": (["VISIONOS", "WEB_EMBED"], nil, sabrHLS),
    ]
    static let sabrHLS = "WEB_EMBED answered SABR-only with an HLS manifest, which Android plays and iOS can't (D48): iOS walks on"

    static var signedOutCases: [String] {
        fixture.cases.filter { $0.exclude == nil && $0.opens.allSatisfy { $0.lane == "signed-out" } }.map(\.name)
    }

    // MARK: Replay

    @Test(arguments: signedOutCases)
    func theWalkDoesWhatTheDeviceDid(caseName: String) async throws {
        let testCase = try #require(Self.fixture.cases.first { $0.name == caseName })
        let clock = ReplayClock()
        // The persisted books outlive an app process, as on the device (route record, wall memory).
        let stores = FileManager.default.temporaryDirectory.appending(path: "replay-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: stores) }
        let routes = stores.appending(path: "routes.json"), wallStore = stores.appending(path: "walls.json")
        func newWalker() -> SourceWalker {
            SourceWalker(now: { clock.now }, date: { clock.date }, network: { "replay" }, routeStore: routes)
        }
        var walker = newWalker()
        var walls = WallBook(storeURL: wallStore, now: { clock.date })
        var visitor = "app-visitor"
        var winners: [String: ClientProfile] = [:]
        var walkNumber = 0
        for open in testCase.opens {
            if open.newProcess == true && walkNumber > 0 {
                // A new app process: what lives in memory is gone; the persisted books are restored.
                walker = newWalker()
                walls = WallBook(storeURL: wallStore, now: { clock.date })
            }
            for step in open.steps {
                clock.set(milliseconds: step.atMs)  // the case's own timeline
                if step.type == "media-failure" {
                    let failed = try #require(winners[step.video], "\(caseName): a media failure before any walk of \(step.video)")
                    let media = try #require(step.media403)
                    await walker.noteMediaRefused(videoID: step.video, client: failed)
                    let verdict = await walls.noteMedia403(videoID: step.video, client: failed, visitor: visitor,
                                                           forbiddenMs: media.forbiddenStartMs, lowestServedMs: media.lowestServedStartMs,
                                                           highestServedMs: media.highestServedStartMs)
                    if verdict.rerollWanted, await walls.spendReroll(videoID: step.video) { visitor += "-rerolled" }
                    continue
                }
                guard step.type == "walk" else { continue }
                let expect = try #require(step.expect)
                let answers = Dictionary((step.answers ?? []).map { ($0.client, $0) }, uniquingKeysWith: { first, _ in first })
                let missing = OSAllocatedUnfairLock(initialState: [String]())
                let suspect = step.suspect.flatMap { id in SourcePlanner.baseOrder.first { $0.id == id } }
                var context = SourcePlanner.Context(lane: .signedOut, recoverySuspect: suspect)
                let plan = await walls.plan(videoID: step.video, recovery: suspect != nil, appVisitor: visitor)
                context.benched = plan.benched
                context.refreshed = plan.refreshed
                context.vodVrLate = suspect != nil || !plan.benched.isEmpty
                let result = await walker.walk(videoID: step.video, context: context) { client, _ in
                    guard let answer = answers[client.id] else {
                        missing.withLock { $0.append(client.id) }
                        return .failed("no device answer")
                    }
                    return Self.rebuild(answer, video: step.video)
                }
                let key = "\(caseName)#\(walkNumber)"
                let change = Self.iosChanges[key]
                // The device's winner is what its media failures blame, whatever iOS settled on.
                if expect.result == "playable", let id = expect.client, let client = SourcePlanner.baseOrder.first(where: { $0.id == id }) {
                    winners[step.video] = client
                }
                if let change, change.client == nil {
                    #expect(Array(result.asked.map(\.id).prefix(change.asked.count)) == change.asked,
                            "\(key): asked \(result.asked.map(\.id)) (iOS: \(change.why))")
                    #expect(!result.playable || result.client?.id != expect.client, "\(key): iOS shouldn't settle as the device did")
                    walkNumber += 1
                    continue
                }
                let device = expect.changed?.asked ?? expect.asked
                let asked = change?.asked ?? device.filter { !Self.skippedClients.contains($0) }
                let label = "\(key) \(step.video)" + (suspect.map { " recovery from \($0.id)" } ?? "")
                    + (expect.changed.map { " (Android now: \($0.why.prefix(60))…)" } ?? "") + (change.map { " (iOS: \($0.why))" } ?? "")
                #expect(missing.withLock { $0 }.isEmpty, "\(label): needs a device answer for \(missing.withLock { $0 })")
                #expect(result.asked.map(\.id) == asked, "\(label): asked \(result.asked.map(\.id)), expected \(asked)")
                #expect(result.playable == (expect.result == "playable"), "\(label): playable \(result.playable), device \(expect.result)")
                #expect(result.client?.id == (change?.client ?? expect.client), "\(label): client \(result.client?.id ?? "-")")
                #expect(result.botCheckTripped == (expect.botCheckTrip ?? false), "\(label): bot-check trip")
                walkNumber += 1
            }
        }
        #expect(walkNumber > 0)
    }

    /// The answer as /player JSON: playability (with the age marker), live flags, and deliveries
    /// matching the logged counts (formats with URLs when usable, without when not; manifests).
    static func rebuild(_ answer: Answer, video: String) -> WalkAttempt {
        guard answer.parsed, let status = answer.status else { return .failed("unparsed") }
        var playability: [String: Any] = ["status": status]
        let reason = answer.exact == true ? answer.exactReason : answer.reason
        if let reason { playability["reason"] = reason }
        if answer.exact == true, let subreason = answer.exactSubreason {
            playability["errorScreen"] = ["playerErrorMessageRenderer": ["subreason": ["simpleText": subreason]]]
        }
        if answer.ageGate { playability["desktopLegacyAgeGateReason"] = 1 }
        var streaming: [String: Any] = [:]
        if answer.adaptive > 0 {
            let withURL = answer.usableAdaptive > 0
            func format(_ itag: Int, _ mime: String) -> [String: Any] {
                var format: [String: Any] = ["itag": itag, "mimeType": mime, "bitrate": 1_000]
                if withURL { format["url"] = "https://rr1---sn-replay.googlevideo.com/videoplayback?itag=\(itag)" }
                return format
            }
            streaming["adaptiveFormats"] = [format(137, #"video/mp4; codecs="avc1.640028""#),
                                            format(140, #"audio/mp4; codecs="mp4a.40.2""#)]
        }
        if answer.hls { streaming["hlsManifestUrl"] = "https://manifest.googlevideo.com/hls" }
        if answer.dash { streaming["dashManifestUrl"] = "https://manifest.googlevideo.com/dash" }
        if answer.sabr { streaming["serverAbrStreamingUrl"] = "https://rr1---sn-replay.googlevideo.com/sabr" }
        let json: [String: Any] = [
            "playabilityStatus": playability,
            "videoDetails": ["videoId": video, "isLive": answer.live, "isLiveContent": answer.liveContent],
            "streamingData": streaming,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: json), let parsed = try? PlayerAnswer(json: data) else {
            return .failed("rebuild")
        }
        return .answer(parsed)
    }

    // MARK: Walk rules beyond the fixture

    @Test func aRepeatedSignInRequestTripsOnlyWhenASecondVideoRepeatsItWithinTenMinutes() async {
        let clock = ReplayClock()
        let walker = SourceWalker(now: { clock.now }, network: { "net" })
        // Every source answers the same localized sign-in request (a bot wall in Spanish).
        let ask: SourceWalker.Ask = { _, _ in Self.answer(status: "LOGIN_REQUIRED", reason: "Inicia sesión para continuar") }
        let first = await walker.walk(videoID: "aaaaaaaaaaa", context: .init(lane: .signedOut), ask: ask)
        #expect(!first.botCheckTripped, "one video proves nothing (a private video answers the same way)")
        clock.set(milliseconds: 5 * 60_000)
        let second = await walker.walk(videoID: "bbbbbbbbbbb", context: .init(lane: .signedOut), ask: ask)
        #expect(second.botCheckTripped, "a second video repeating it within 10 min trips the circuit")
        clock.set(milliseconds: 5 * 60_000 + 20_000)
        let third = await walker.walk(videoID: "ccccccccccc", context: .init(lane: .signedOut), ask: ask)
        #expect(third.fromCircuit && third.asked.isEmpty, "the circuit answers without a request")
        clock.set(milliseconds: 5 * 60_000 + 90_000)
        let probe = await walker.walk(videoID: "ddddddddddd", context: .init(lane: .signedOut)) { _, _ in
            Self.answer(status: "OK", playable: true)
        }
        #expect(probe.playable && probe.asked.count == 1, "one probe a minute goes through")
    }

    @Test func twoSilentAttemptsInARowStopTheWalkWithoutAVerdict() async {
        let walker = SourceWalker()
        let result = await walker.walk(videoID: "aaaaaaaaaaa", context: .init(lane: .signedOut)) { _, _ in .noResponse }
        #expect(result.asked.map(\.id) == ["VISIONOS", "WEB_EMBED"])
        #expect(result.answer == nil && !result.playable, "a dead link establishes nothing")
    }

    @Test func theWalkBudgetStopsAskingAfter45Seconds() async {
        let clock = ReplayClock()
        let walker = SourceWalker(now: { clock.now })
        let result = await walker.walk(videoID: "aaaaaaaaaaa", context: .init(lane: .signedOut)) { _, _ in
            clock.advance(milliseconds: 20_000)  // each source answers a generic refusal after 20 s
            return Self.answer(status: "UNPLAYABLE", reason: "Something else", web: true)
        }
        #expect(result.asked.count == 3, "45 s fits 2 attempts of 20 s and a third start (asked \(result.asked.map(\.id)))")
        #expect(result.answer == nil)
    }

    static func answer(status: String, reason: String? = nil, playable: Bool = false, web: Bool = false) -> WalkAttempt {
        var playability: [String: Any] = ["status": status]
        if let reason { playability["reason"] = reason }
        var json: [String: Any] = ["playabilityStatus": playability]
        if playable {
            json["streamingData"] = ["adaptiveFormats": [
                ["itag": 140, "mimeType": #"audio/mp4; codecs="mp4a.40.2""#, "url": "https://x.googlevideo.com/v"]]]
        }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return .answer(try! PlayerAnswer(json: data))
    }
}

/// A clock the test moves.
final class ReplayClock: Sendable {
    private let origin = ContinuousClock.now
    private let originDate = Date(timeIntervalSince1970: 1_790_000_000)
    var date: Date { originDate.addingTimeInterval(Double(offset.withLock { $0 } / .milliseconds(1)) / 1000) }
    private let offset = OSAllocatedUnfairLock(initialState: Duration.zero)
    var now: ContinuousClock.Instant { origin + offset.withLock { $0 } }
    func set(milliseconds: Int) { offset.withLock { $0 = .milliseconds(milliseconds) } }
    func advance(milliseconds: Int) { offset.withLock { $0 += .milliseconds(milliseconds) } }
}
