import Foundation
import Testing
@testable import YouTubeEngine

/// US-008: request bodies byte-compatible with MediaServiceCore's QueryBuilder.
@Suite struct PlayerRequestBodyTests {
    /// Reconstructed by hand from QueryBuilder.kt (52fecea0): the template's lines trimmed and
    /// joined, the trailing object commas removed. VISIONOS has browser fields (Safari/605.1.15 from
    /// its UA), its device fragment without spaces, Xhr true, no thirdParty, no PO token.
    static let visionOSExpected = #"{"context": {"client": {"clientName": "VISIONOS","clientVersion": "1.02","clientScreen": "WATCH","userAgent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15","browserName": "Safari","browserVersion": "605.1.15","deviceMake":"Apple","deviceModel":"RealityDevice17,1","osName":"visionOS","osVersion":"26.5.23O471","acceptLanguage": "en-US","acceptRegion": "US","utcOffsetMinutes": "180","visitorData": "CgtWSVNJVE9SX0lEKOGv0rAG"},"user":{"enableSafetyMode": false,"lockedSafetyMode":false}},"playbackContext": {"contentPlaybackContext": {"html5Preference": "HTML5_PREF_WANTS","lactMilliseconds": 60000,"isInlinePlaybackNoAd": true,"signatureTimestamp": 20717},"devicePlaybackCapabilities": {"supportsVp9Encoding": true,"supportXhr": true}},"racyCheckOk": true,"contentCheckOk": true,"videoId": "dQw4w9WgXcQ","cpn": "AbCdEfGhIjKlMn-_"}"#

    static func body(_ client: ClientProfile = .visionOS, visitor: String? = "CgtWSVNJVE9SX0lEKOGv0rAG",
                     sts: Int = 20717, flags: String? = nil) -> PlayerRequestBody {
        PlayerRequestBody(client: client, videoID: "dQw4w9WgXcQ", cpn: "AbCdEfGhIjKlMn-_", visitorData: visitor,
                          signatureTimestamp: sts, acceptLanguage: "en-US", acceptRegion: "US",
                          utcOffsetMinutes: 180, encryptedHostFlags: flags)
    }

    @Test func visionOSBodyMatchesQueryBuilderByteForByte() throws {
        let json = Self.body().json
        #expect(json == Self.visionOSExpected)
        _ = try JSONSerialization.jsonObject(with: Data(json.utf8))  // and it is valid JSON
    }

    @Test func unknownTimestampAndNoVisitor() throws {
        let json = Self.body(visitor: nil, sts: -1).json
        #expect(json.contains(#""signatureTimestamp": -1}"#))
        #expect(!json.contains("visitorData"))
        #expect(json.contains(#""utcOffsetMinutes": "180"},"user""#), "no dangling comma after the region")
        _ = try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    @Test func webEmbedCarriesThirdPartyAndItsHostFlags() throws {
        let json = Self.body(.webEmbed, flags: "FLAGS").json
        #expect(json.contains(#""lockedSafetyMode":false},"thirdParty": {"embedUrl": "https://www.reddit.com/"}},"#))
        #expect(json.contains(#""signatureTimestamp": 20717,"encryptedHostFlags":"FLAGS"},"#))
        #expect(json.contains(#""supportXhr": false"#))
        #expect(json.contains(#""browserName": "Safari","browserVersion": "605.1.15""#))
        _ = try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    @Test func reelWrapsTheVideoDataAndAppClientsHaveNoBrowserFields() throws {
        let json = Self.body(.androidReel).json
        #expect(json.contains(#""playerRequest": {"racyCheckOk": true,"contentCheckOk": true,"videoId": "dQw4w9WgXcQ","cpn": "AbCdEfGhIjKlMn-_"}}"#))
        #expect(!json.contains("browserName"))
        #expect(json.contains(#""androidSdkVersion":"30","osName":"Android","osVersion":"11","acceptLanguage""#))
        _ = try JSONSerialization.jsonObject(with: Data(json.utf8))
    }

    @Test func browserFieldsAreSniffedLikeAppClient() {
        #expect(ClientProfile.visionOS.browser?.name == "Safari")
        #expect(ClientProfile.visionOS.browser?.version == "605.1.15")
        #expect(ClientProfile.tvTizen.browser?.version == "538.1")
        #expect(ClientProfile.webEmbed.browser?.version == "605.1.15")
        #expect(ClientProfile.androidVR.browser == nil)
        #expect(ClientProfile.iOS.browser == nil)
    }

    @Test func trailingCommasGoButCommasInsideStringsStay() {
        #expect(PlayerRequestBody.removeTrailingObjectCommas(#"{"a": 1,}"#) == #"{"a": 1}"#)
        #expect(PlayerRequestBody.removeTrailingObjectCommas(#"{"a": ",}",}"#) == #"{"a": ",}"}"#)
        #expect(PlayerRequestBody.removeTrailingObjectCommas(#"{"a": "\",}",}"#) == #"{"a": "\",}"}"#)
    }

    @Test func cpnIsSixteenCharactersOfYouTubesAlphabet() {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let cpn = PlayerRequestBody.makeCPN()
        #expect(cpn.count == 16)
        #expect(cpn.allSatisfy { allowed.contains($0) })
    }
}
