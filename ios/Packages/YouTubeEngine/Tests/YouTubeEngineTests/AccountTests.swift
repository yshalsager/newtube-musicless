import Foundation
import os
import Testing
@testable import YouTubeEngine

/// US-022: the TV device-code sign-in, the account row, the signed-in walk, and the history pings.
@Suite struct AccountTests {
    @Test func theBaseScriptAndItsFirstClientAreFound() {
        // The Cobalt page's script tag (the path seen on 2026-11-26), and the first of several clients.
        let page = #"<script>var s = document.createElement('script'); s.src = '/s/_/kabuki/_/js/k=kabuki.base_cr.en_US.x.es6.O/am=A/m=base'; document.head.appendChild(s);</script>"#
        #expect(OAuthClient.baseScriptPath(in: page) == "https://www.youtube.com/s/_/kabuki/_/js/k=kabuki.base_cr.en_US.x.es6.O/am=A/m=base")
        #expect(OAuthClient.baseScriptPath(in: #"<script id="base-js" src="/s/a/m=base" nonce="x"></script>"#) == "https://www.youtube.com/s/a/m=base")
        #expect(OAuthClient.baseScriptPath(in: "<html></html>") == nil)
        let script = #"x={clientId:"111-abc.apps.googleusercontent.com",Qb:"FirstSecret1"};y={clientId:"222-def.apps.googleusercontent.com",Qb:"OtherSecret"}"#
        #expect(OAuthClient.clientData(in: script) == OAuthClientData(clientID: "111-abc.apps.googleusercontent.com", clientSecret: "FirstSecret1"),
                "the first occurrence: later ones are other clients (401)")
        #expect(OAuthClient.clientData(in: "nothing") == nil)
    }

    @Test func tokenAnswersAndErrors() {
        #expect(OAuthClient.error("authorization_pending") == .pending)
        #expect(OAuthClient.error("slow_down") == .slowDown)
        #expect(OAuthClient.error("expired_token") == .expired)
        #expect(OAuthClient.error("access_denied") == .denied)
        #expect(OAuthClient.error("invalid_grant") == .invalidGrant)
        let token = OAuthClient.accessToken(["access_token": "ya29.x", "expires_in": 3600, "token_type": "Bearer"])
        #expect(token?.authorization == "Bearer ya29.x")
        #expect(token.map { abs($0.expiresAt.timeIntervalSinceNow - 3600) < 5 } == true)
        #expect(OAuthClient.accessToken(["error": "invalid_grant"]) == nil)
    }

    @Test func theAccountRowIsTheSelectedAccount() throws {
        let json = #"{"contents":[{"accountSectionListRenderer":{"contents":[{"accountItemSectionRenderer":{"contents":[{"accountItem":{"accountName":{"simpleText":"Brand"},"isSelected":false}},{"accountItem":{"accountName":{"simpleText":"Someone"},"accountByline":{"simpleText":"someone@example.com"},"channelHandle":{"simpleText":"@someone"},"accountPhoto":{"thumbnails":[{"url":"https://yt3.ggpht.com/a=s48","width":48},{"url":"https://yt3.ggpht.com/a=s88","width":88}]},"isSelected":true}}]}}]}}]}"#
        let account = try FeedParser.account(Data(json.utf8))
        #expect(account.name == "Someone" && account.byline == "someone@example.com" && account.handle == "@someone")
        #expect(account.avatar?.absoluteString == "https://yt3.ggpht.com/a=s88")
        #expect(throws: BrowseError.self) { try FeedParser.account(Data(#"{"contents":[]}"#.utf8)) }
    }

    @Test func theTrackingComesFromTheVideostatsURL() throws {
        let answer = try PlayerAnswer(json: Data(#"{"playabilityStatus":{"status":"OK"},"playbackTracking":{"videostatsPlaybackUrl":{"baseUrl":"https://s.youtube.com/api/stats/playback?cl=1&docid=abc&ei=EVENT&fexp=1&ns=yt&plid=P&el=detailpage&len=100&of=OFPARAM&vm=VMDATA"}}}"#.utf8))
        let tracking = try #require(WatchHistory.Tracking(videostatsURL: answer.videostatsPlaybackURL, cpn: "CPN"))
        #expect(tracking.eventID == "EVENT" && tracking.visitorMonitoring == "VMDATA" && tracking.of == "OFPARAM" && tracking.cpn == "CPN")
        #expect(WatchHistory.Tracking(videostatsURL: "https://s.youtube.com/api/stats/playback?ei=E", cpn: "C") == nil)
    }

    @Test func thePingsFollowTrackingService() throws {
        let tracking = try #require(WatchHistory.Tracking(videostatsURL: "https://x/?ei=E&vm=V&of=O", cpn: "C"))
        var history = WatchHistory()
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        // First ping, 10 s in: a new record from 0 (under 3 min), then the watch time 0 → 10.
        let first = history.pings(videoID: "v", position: 10, length: 600, tracking: tracking, now: start)
        #expect(first.map(\.path) == ["/api/stats/playback", "/api/stats/watchtime"])
        #expect(Self.query(first[0])["cmt"] == "0.000" && Self.query(first[1])["st"] == "0.000" && Self.query(first[1])["et"] == "10.000")
        #expect(Self.query(first[1])["ei"] == "E" && Self.query(first[1])["vm"] == "V" && Self.query(first[1])["of"] == "O" && Self.query(first[1])["cpn"] == "C")
        // A minute later at 70 s: only the watch time, from the last position.
        let second = history.pings(videoID: "v", position: 70, length: 600, tracking: tracking, now: start.addingTimeInterval(60))
        #expect(second.map(\.path) == ["/api/stats/watchtime"] && Self.query(second[0])["st"] == "10.000")
        // Within the last 5 %: marked as fully watched.
        let end = history.pings(videoID: "v", position: 590, length: 600, tracking: tracking, now: start.addingTimeInterval(120))
        #expect(end.allSatisfy { Self.query($0)["final"] == "1" } && end.count == 2)
        // Another video resumed at 5 min: its record starts there.
        let other = history.pings(videoID: "w", position: 300, length: 900, tracking: tracking, now: start.addingTimeInterval(130))
        #expect(Self.query(other[0])["cmt"] == "300.000")
        // Half an hour without a ping renews the record.
        let renewed = history.pings(videoID: "w", position: 320, length: 900, tracking: tracking, now: start.addingTimeInterval(130 + 31 * 60))
        #expect(renewed.map(\.path) == ["/api/stats/playback", "/api/stats/watchtime"])
    }

    @Test func signedInTheAccountRouteIsSecondWithFifteenSeconds() async {
        let asked = OSAllocatedUnfairLock(initialState: [(String, Duration)]())
        let walker = SourceWalker(network: { "net" })
        let result = await walker.walk(videoID: "aaaaaaaaaaa", context: .init(lane: .signedIn)) { client, budget in
            asked.withLock { $0.append((client.id, budget)) }
            return client == .tvTizen ? WalkReplayTests.answer(status: "OK", playable: true)
                : WalkReplayTests.answer(status: "UNPLAYABLE", reason: "This video is not available")
        }
        let calls = asked.withLock { $0 }
        #expect(result.playable && result.client == .tvTizen)
        #expect(calls.map(\.0).prefix(2) == ["VISIONOS", "TV_TIZEN"])
        #expect(calls.first { $0.0 == "TV_TIZEN" }?.1 == .seconds(15), "Android's budget with the account")
    }

    static func query(_ url: URL) -> [String: String] {
        Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") },
                   uniquingKeysWith: { first, _ in first })
    }
}
