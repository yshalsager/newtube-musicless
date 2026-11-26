import Foundation

/// The TV device-code sign-in (US-022; PRD §4.4), as MediaServiceCore's `AuthService` (V2) does it:
/// the client id and secret come from the youtube.com/tv app's base script (`ClientData`), a user
/// code is shown, the user approves it at yt.be/activate, and the token endpoint is polled until it
/// gives a refresh token. Access tokens are minted from the refresh token when needed.
///
/// Nothing here logs a token, a code, the client id or the secret.
public struct OAuthClientData: Codable, Sendable, Equatable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }
}

public struct DeviceCode: Sendable, Equatable {
    public var deviceCode: String
    public var userCode: String
    public var verificationURL: URL
    public var expiresIn: TimeInterval
    public var interval: TimeInterval
}

/// What the account keeps: the refresh token and the client it was minted for (a refresh needs
/// the same client; AuthService.updateAccessTokenRaw keeps the raw auth data for that).
public struct AccountCredentials: Codable, Sendable, Equatable {
    public var refreshToken: String
    public var client: OAuthClientData

    public init(refreshToken: String, client: OAuthClientData) {
        self.refreshToken = refreshToken
        self.client = client
    }
}

public struct AccessToken: Sendable, Equatable {
    public var token: String
    public var expiresAt: Date

    public var authorization: String { "Bearer \(token)" }
}

public enum OAuthError: Error, Equatable, CustomStringConvertible {
    /// Not approved yet: poll again after the interval.
    case pending
    /// Polling too fast: add 5 s to the interval.
    case slowDown
    case expired
    case denied
    /// The refresh token no longer works (revoked, or the client changed): sign in again.
    case invalidGrant
    case failed(String)

    public var description: String {
        switch self {
        case .pending: "authorization_pending"
        case .slowDown: "slow_down"
        case .expired: "expired_token"
        case .denied: "access_denied"
        case .invalidGrant: "invalid_grant"
        case .failed(let reason): reason
        }
    }
}

public struct OAuthClient: Sendable {
    static let tvURL = URL(string: "https://www.youtube.com/tv")!
    static let deviceCodeURL = URL(string: "https://www.youtube.com/o/oauth2/device/code")!
    static let tokenURL = URL(string: "https://www.youtube.com/o/oauth2/token")!
    /// AuthApiHelper: the TV app's scope and model name, and the device grant.
    static let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"
    static let modelName = "ytlr::"
    static let deviceGrant = "http://oauth.net/grant_type/device/1.0"

    private let transport: InnerTubeTransport
    private let log: @Sendable (String) -> Void

    public init(transport: InnerTubeTransport, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.transport = transport
        self.log = log
    }

    // MARK: The client id and secret (AppInfo.mClientUrl, ClientData)

    public func clientData() async throws -> OAuthClientData {
        var request = URLRequest(url: Self.tvURL, timeoutInterval: 20)
        request.setValue(VisitorIdentity.fireTVUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(VisitorIdentity.consentCookie, forHTTPHeaderField: "Cookie")
        let page = String(decoding: try await transport.send(request, label: "tv").data, as: UTF8.self)
        guard let path = Self.baseScriptPath(in: page), let url = URL(string: path, relativeTo: Self.tvURL)?.absoluteURL else {
            throw OAuthError.failed("no base script on youtube.com/tv")
        }
        let script = String(decoding: try await transport.send(URLRequest(url: url, timeoutInterval: 20), label: "tv-base").data,
                            as: UTF8.self)
        guard let data = Self.clientData(in: script) else { throw OAuthError.failed("no client id in the base script") }
        log("oauth client-data found script=\(url.lastPathComponent)")
        return data
    }

    /// AppInfo's three patterns for the base script's URL.
    static func baseScriptPath(in page: String) -> String? {
        for pattern in [#"id="base-js" src="(.*?)""#, #"\.src = '(.*?m=base)'"#, #"\.src = '(.*?)'; .\.id = 'base-js'"#] {
            if let match = VisitorIdentity.match(pattern, in: page) { return VisitorIdentity.tidyURL(match) }
        }
        return nil
    }

    /// ClientData: the first `clientId:"….apps.googleusercontent.com",x:"secret"` (later ones are
    /// other clients and give 401).
    static func clientData(in script: String) -> OAuthClientData? {
        let pattern = #"clientId:"([-\w]+\.apps\.googleusercontent\.com)",\n?[$\w]+:"(\w+)""#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: script, range: NSRange(script.startIndex..., in: script)),
              let id = Range(match.range(at: 1), in: script), let secret = Range(match.range(at: 2), in: script) else { return nil }
        return OAuthClientData(clientID: String(script[id]), clientSecret: String(script[secret]))
    }

    // MARK: The flow

    /// AuthService.getUserCode.
    public func deviceCode(client: OAuthClientData, deviceID: String) async throws -> DeviceCode {
        let json = try await post(Self.deviceCodeURL, ["client_id": client.clientID, "device_id": deviceID,
                                                      "model_name": Self.modelName, "scope": Self.scope])
        guard let deviceCode = json["device_code"] as? String, let userCode = json["user_code"] as? String else {
            throw OAuthError.failed(json["error"] as? String ?? "no device code")
        }
        let url = (json["verification_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://yt.be/activate")!
        log("oauth device-code expiresIn=\(json["expires_in"] as? Int ?? 0) interval=\(json["interval"] as? Int ?? 0)")
        return DeviceCode(deviceCode: deviceCode, userCode: userCode, verificationURL: url,
                          expiresIn: TimeInterval(json["expires_in"] as? Int ?? 1800), interval: TimeInterval(json["interval"] as? Int ?? 5))
    }

    /// One poll of the token endpoint (AuthService.getAccessToken): the refresh token once approved.
    public func poll(_ code: DeviceCode, client: OAuthClientData) async throws -> (AccountCredentials, AccessToken) {
        let json = try await post(Self.tokenURL, ["code": code.deviceCode, "client_id": client.clientID,
                                                 "client_secret": client.clientSecret, "grant_type": Self.deviceGrant])
        if let error = json["error"] as? String { throw Self.error(error) }
        guard let refresh = json["refresh_token"] as? String, let access = Self.accessToken(json) else {
            throw OAuthError.failed("no refresh token")
        }
        log("oauth signed-in")
        return (AccountCredentials(refreshToken: refresh, client: client), access)
    }

    /// AuthService.updateAccessToken.
    public func refresh(_ credentials: AccountCredentials) async throws -> AccessToken {
        let json = try await post(Self.tokenURL, ["refresh_token": credentials.refreshToken, "client_id": credentials.client.clientID,
                                                 "client_secret": credentials.client.clientSecret, "grant_type": "refresh_token"])
        if let error = json["error"] as? String { throw Self.error(error) }
        guard let access = Self.accessToken(json) else { throw OAuthError.failed("no access token") }
        log("oauth refreshed expiresIn=\(Int(access.expiresAt.timeIntervalSinceNow))")
        return access
    }

    static func accessToken(_ json: [String: Any]) -> AccessToken? {
        guard let token = json["access_token"] as? String else { return nil }
        let expiresIn = TimeInterval(json["expires_in"] as? Int ?? 3600)
        return AccessToken(token: token, expiresAt: Date().addingTimeInterval(expiresIn))
    }

    static func error(_ code: String) -> OAuthError {
        switch code {
        case "authorization_pending": .pending
        case "slow_down": .slowDown
        case "expired_token": .expired
        case "access_denied": .denied
        case "invalid_grant": .invalidGrant
        default: .failed(code)
        }
    }

    private func post(_ url: URL, _ fields: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        let response = try await transport.send(request, label: "oauth")
        guard let json = try? JSONSerialization.jsonObject(with: response.data) as? [String: Any] else {
            throw OAuthError.failed("HTTP \(response.status)")
        }
        return json
    }
}
