import Foundation

/// The `/player` request body, byte-compatible with MediaServiceCore's `QueryBuilder.build()` for a
/// player request (QueryBuilder.kt:79-411 at `52fecea0`).
///
/// It is built the way QueryBuilder builds it: a multi-line template whose lines are trimmed and
/// joined with nothing between them, then commas before a closing brace are removed outside
/// strings. So `"key": value` keeps its space where the template has one (`"clientName": "…"`)
/// and the device fragments have none (`"osName":"visionOS"`). The test compares the result with a
/// body reconstructed from the Kotlin template.
public struct PlayerRequestBody: Sendable {
    public var client: ClientProfile
    public var videoID: String
    public var cpn: String
    /// `context.client.visitorData`; nil omits the field.
    public var visitorData: String?
    /// The TV player JS's timestamp, or -1 when unknown (QueryBuilder's sentinel).
    public var signatureTimestamp: Int
    /// BCP-47 language tag (`Locale.toLanguageTag()` on Android), e.g. `en-US`.
    public var acceptLanguage: String
    /// Country code, e.g. `US`.
    public var acceptRegion: String
    public var utcOffsetMinutes: Int
    /// From a card's `clickTrackingParams`; nil omits `context.clickTracking`.
    public var clickTrackingParams: String?
    /// WEB_EMBED only: bound to the embed page's visitor.
    public var encryptedHostFlags: String?

    public init(client: ClientProfile, videoID: String, cpn: String, visitorData: String?, signatureTimestamp: Int,
                acceptLanguage: String, acceptRegion: String, utcOffsetMinutes: Int,
                clickTrackingParams: String? = nil, encryptedHostFlags: String? = nil) {
        self.client = client
        self.videoID = videoID
        self.cpn = cpn
        self.visitorData = visitorData
        self.signatureTimestamp = signatureTimestamp
        self.acceptLanguage = acceptLanguage
        self.acceptRegion = acceptRegion
        self.utcOffsetMinutes = utcOffsetMinutes
        self.clickTrackingParams = clickTrackingParams
        self.encryptedHostFlags = encryptedHostFlags
    }

    /// The JSON string, exactly as QueryBuilder would send it.
    public var json: String {
        let template = """
             {
                "context": {
                     \(clientChunk)
                     \(clickTrackingChunk)
                     \(userChunk)
                     \(embeddedChunk)
                },
                \(timestampChunk)
                \(videoDataChunk)
             }
        """
        let joined = template.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .joined()
        return Self.removeTrailingObjectCommas(joined)
    }

    public var data: Data { Data(json.utf8) }

    // MARK: Chunks (QueryBuilder's create*Chunk, in its order)

    private var clientChunk: String {
        var browserVars = ""
        if let browser = client.browser {
            browserVars = """
                "browserName": "\(browser.name)",
                "browserVersion": "\(browser.version)",
            """
        }
        let visitorVar = visitorData.map { " \"visitorData\": \"\($0)\" " } ?? ""
        return """
             "client": {
                "clientName": "\(client.clientName)",
                "clientVersion": "\(client.clientVersion)",
                "clientScreen": "\(client.clientScreen)",
                "userAgent": "\(client.userAgent)",
                \(browserVars)
                \(client.deviceFields)
                "acceptLanguage": "\(acceptLanguage)",
                "acceptRegion": "\(acceptRegion)",
                "utcOffsetMinutes": "\(utcOffsetMinutes)",
                \(visitorVar)
             },
        """
    }

    private var clickTrackingChunk: String {
        guard let clickTrackingParams else { return "" }
        return """
            "clickTracking": {
                "clickTrackingParams": "\(clickTrackingParams)"
            },
        """
    }

    private var userChunk: String {
        """
           "user":{
                "enableSafetyMode": false,
                "lockedSafetyMode":false
           },
        """
    }

    private var embeddedChunk: String {
        guard client.isEmbedded else { return "" }
        return """
            "thirdParty": {
                "embedUrl": "https://www.reddit.com/"
            },
        """
    }

    private var timestampChunk: String {
        var flags = ""
        if client.isEmbedded, let encryptedHostFlags {
            flags = "\"encryptedHostFlags\":\"\(encryptedHostFlags)\","
        }
        return """
            "playbackContext": {
                "contentPlaybackContext": {
                    "html5Preference": "HTML5_PREF_WANTS",
                    "lactMilliseconds": 60000,
                    "isInlinePlaybackNoAd": true,
                    "signatureTimestamp": \(signatureTimestamp),
                    \(flags)
                },
                "devicePlaybackCapabilities": {
                    "supportsVp9Encoding": true,
                    "supportXhr": \(client.supportXhr)
                }
            },
        """
    }

    private var videoDataChunk: String {
        let data = """
            "racyCheckOk": true,
            "contentCheckOk": true,
            "videoId": "\(videoID)",
            "cpn": "\(cpn)",
        """
        guard client.id == ClientProfile.androidReel.id else { return data }
        return """
            "playerRequest": {
                \(data)
            },
        """
    }

    /// QueryBuilder.removeTrailingObjectCommas: drop a comma whose next non-space is `}`, outside
    /// quoted strings (a literal ",}" inside a field is data).
    static func removeTrailingObjectCommas(_ json: String) -> String {
        let characters = Array(json)
        var result = ""
        result.reserveCapacity(characters.count)
        var quoted = false, escaped = false
        for (index, character) in characters.enumerated() {
            if quoted {
                result.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
                continue
            }
            if character == "\"" {
                quoted = true
            } else if character == "," {
                var next = index + 1
                while next < characters.count, characters[next].isWhitespace { next += 1 }
                if next < characters.count, characters[next] == "}" { continue }
            }
            result.append(character)
        }
        return result
    }

    /// A 16-character client playback nonce from YouTube's alphabet
    /// (`RandomStringFromAlphabetGenerator`, `YouTubeHelper.generateCPNParameter`).
    public static func makeCPN() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<16).map { _ in alphabet.randomElement()! })
    }
}
