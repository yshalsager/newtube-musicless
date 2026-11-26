/// An InnerTube client identity: what goes on the wire for one `AppClient`.
///
/// Copied from MediaServiceCore at `52fecea0` (2026-10-20) on 2026-11-25:
/// - names, versions, devices: `youtubeapi/…/innertube/utils/Constants.kt` (`CLIENTS`, `CLIENT_NAME_IDS`);
/// - user agents: `googlecommon/…/common/helpers/DefaultHeaders.kt` and `Constants.kt`;
/// - device fragments and screens: `youtubeapi/…/common/helpers/AppClient.kt` (`POST_DATA_*`, the enum);
/// - `supportXhr` and identities: `videoinfo/V2/sources/PlayerSourceCatalog.java`;
/// - per-attempt timeouts: docs/player-sources/LANES.md §2.4 (`VideoInfoService`).
/// **Client versions churn**: resync this table from those files, not from memory.
public struct ClientProfile: Sendable, Hashable {
    /// The `AppClient` enum name, also the `client=` field of logs.
    public let id: String
    public let clientName: String
    public let clientVersion: String
    /// `X-Youtube-Client-Name`.
    public let clientNameID: String
    public let userAgent: String
    public let clientScreen: String
    /// `AppClient.postData`: device fields spliced into `context.client`, each ending with a comma.
    public let deviceFields: String
    /// `devicePlaybackCapabilities.supportXhr`.
    public let supportXhr: Bool
    /// Embedded clients send `thirdParty.embedUrl` (and their embed page's identity).
    public let isEmbedded: Bool
    /// Per-attempt budget inside a source walk (LANES §2.4).
    public let attemptTimeout: Duration

    /// `browserName` / `browserVersion`, sniffed from the UA as `AppClient.extractBrowserInfo` does:
    /// the first of SamsungBrowser, LG Browser, Cobalt, Chrome, Safari with a `<name>/<version>`.
    public var browser: (name: String, version: String)? {
        for name in ["SamsungBrowser", "LG Browser", "Cobalt", "Chrome", "Safari"]
        where userAgent.range(of: name, options: .caseInsensitive) != nil {
            guard let range = userAgent.range(of: "\(name)/") else { continue }
            let version = userAgent[range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
            if !version.isEmpty { return (name, String(version)) }
            return nil
        }
        return nil
    }

    /// Android's `AppClient.isWebPotRequired` (WEB, MWEB, WEB_EMBED, WEB_SAFARI, …): of the sources
    /// iOS asks, only WEB_EMBED. The walk reads it: such a source's refusal doesn't admit TV_TIZEN,
    /// it isn't an unchallenged fallback after a bot check, and it goes last when the anonymous web
    /// identity is challenged.
    public var isWebPotRequired: Bool { id == "WEB_EMBED" }

    /// Which visitor a request rides (Android's `PlayerSource.Identity`). On iOS every source uses the
    /// youtube.com/tv visitor except WEB_EMBED, which rides its embed page's (PRD §4.4, D37), so
    /// terminal consensus has two identities to count where Android has three (D46).
    public enum Identity: String, Sendable { case appVisitor, embedPage }
    public var identity: Identity { isEmbedded ? .embedPage : .appVisitor }

    public static func == (lhs: ClientProfile, rhs: ClientProfile) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension ClientProfile {
    /// The phone's first source (D8): no cipher, no PO token, no ads. Constants.kt:107-115,
    /// AppClient.kt:88-91 (`POST_DATA_VISIONOS_DEVICE`), name id 101; PlayerSourceCatalog Xhr.TRUE.
    public static let visionOS = ClientProfile(
        id: "VISIONOS", clientName: "VISIONOS", clientVersion: "1.02", clientNameID: "101",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        clientScreen: "WATCH",
        deviceFields: #""deviceMake":"Apple","deviceModel":"RealityDevice17,1","osName":"visionOS","osVersion":"26.5.23O471","#,
        supportXhr: true, isEmbedded: false, attemptTimeout: .seconds(7))

    /// TVHTML5 5.x as a Samsung Tizen TV: the account route, and anonymous after a content refusal.
    /// AppClient.kt:26-30 (`POST_DATA_TIZEN_DEVICE`, `USER_AGENT_TIZEN`), :123; Xhr.FALSE. Ciphered.
    public static let tvTizen = ClientProfile(
        id: "TV_TIZEN", clientName: "TVHTML5", clientVersion: "5.20260707", clientNameID: "7",
        userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
        clientScreen: "WATCH",
        deviceFields: #""deviceMake":"Samsung","deviceModel":"SmartTV","osName":"Tizen","osVersion":"2.4.0","#,
        supportXhr: false, isEmbedded: false, attemptTimeout: .seconds(7))

    /// WEB_EMBEDDED_PLAYER on its embed page's identity. Constants.kt (`WEB_EMBEDDED`), name id 56,
    /// DefaultHeaders.kt:76 (`USER_AGENT_SAFARI`); Xhr.FALSE. Needs `n` solving.
    public static let webEmbed = ClientProfile(
        id: "WEB_EMBED", clientName: "WEB_EMBEDDED_PLAYER", clientVersion: "2.20260708.00.00", clientNameID: "56",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
        clientScreen: "WATCH", deviceFields: "",
        supportXhr: false, isEmbedded: true, attemptTimeout: .seconds(20))

    /// The live-DASH source. Constants.kt (`ANDROID_VR`), AppClient.kt:76-79, name id 28; Xhr.TRUE.
    public static let androidVR = ClientProfile(
        id: "ANDROID_VR", clientName: "ANDROID_VR", clientVersion: "1.65.10", clientNameID: "28",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        clientScreen: "WATCH",
        deviceFields: #""androidSdkVersion":"32","osName":"Android","osVersion":"12L","deviceModel":"Quest 3","deviceMake":"Oculus","#,
        supportXhr: true, isEmbedded: false, attemptTimeout: .seconds(7))

    /// ANDROID through `reel/reel_item_watch` (progressive formats). Constants.kt (`ANDROID`),
    /// AppClient.kt:71-75, name id 3; Xhr.TRUE. Its body wraps the video data in `playerRequest`.
    public static let androidReel = ClientProfile(
        id: "ANDROID_REEL", clientName: "ANDROID", clientVersion: "21.26.364", clientNameID: "3",
        userAgent: "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip",
        clientScreen: "WATCH",
        deviceFields: #""androidSdkVersion":"30","osName":"Android","osVersion":"11","#,
        supportXhr: true, isEmbedded: false, attemptTimeout: .seconds(7))

    /// Constants.kt (`IOS`), AppClient.kt:80-81 (`POST_DATA_IOS_MODEL`), name id 5; Xhr.TRUE.
    public static let iOS = ClientProfile(
        id: "IOS", clientName: "iOS", clientVersion: "21.26.4", clientNameID: "5",
        userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        clientScreen: "WATCH",
        deviceFields: #""deviceModel":"iPhone16,2","osVersion":"18.3.2.22D82","#,
        supportXhr: true, isEmbedded: false, attemptTimeout: .seconds(7))

    /// The sources iOS asks, in the signed-out lane's order (LANES §2.1; web clients needing PO
    /// tokens are skipped on iOS, PRD §4.4).
    public static let all: [ClientProfile] = [.visionOS, .tvTizen, .webEmbed, .androidVR, .androidReel, .iOS]
}
