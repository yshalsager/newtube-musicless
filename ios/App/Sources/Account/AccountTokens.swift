import Foundation
import Security
import YouTubeEngine

/// The account's secrets, in the Keychain only (US-022; PRD §4.4): the refresh token and the
/// client it was minted for. `AfterFirstUnlockThisDeviceOnly`, so a locked phone playing in the
/// background can still refresh, and nothing leaves this device (no iCloud Keychain, no backup).
enum Keychain {
    private static let service = "musicless.account"

    static func load(_ account: String) -> Data? {
        var query = base(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    static func save(_ data: Data, for account: String) -> Bool {
        SecItemDelete(base(account) as CFDictionary)
        var item = base(account)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func delete(_ account: String) {
        SecItemDelete(base(account) as CFDictionary)
    }

    private static func base(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
}

/// The access token, minted from the Keychain's refresh token when needed (60 s before it
/// expires), one refresh at a time. A refused refresh token (revoked, or the client changed) signs
/// out. Never logs a token.
actor AccountTokens {
    private static let credentialsKey = "credentials"
    private let oauth: OAuthClient
    private var credentials: AccountCredentials?
    private var access: AccessToken?
    private var refreshing: Task<AccessToken?, Never>?
    /// Called on the main actor when a refresh finds the account gone.
    private var onSignedOut: (@MainActor @Sendable () -> Void)?

    init(oauth: OAuthClient) {
        self.oauth = oauth
        credentials = Keychain.load(Self.credentialsKey).flatMap { try? JSONDecoder().decode(AccountCredentials.self, from: $0) }
    }

    var isSignedIn: Bool { credentials != nil }

    func setOnSignedOut(_ handler: @escaping @MainActor @Sendable () -> Void) { onSignedOut = handler }

    /// `Bearer …` for the account, or nil signed out (or when no token can be had right now).
    func authorization() async -> String? {
        guard let credentials else { return nil }
        if let access, access.expiresAt.timeIntervalSinceNow > 60 { return access.authorization }
        if let refreshing { return await refreshing.value?.authorization }
        let oauth = oauth
        let task = Task<AccessToken?, Never> {
            do {
                return try await oauth.refresh(credentials)
            } catch OAuthError.invalidGrant {
                self.signOut(reason: "refresh refused")
                return nil
            } catch {
                AppLog.netPath.info("account refresh failed error=\(error)")
                return nil
            }
        }
        refreshing = task
        let token = await task.value
        refreshing = nil
        if let token { access = token }
        return token?.authorization
    }

    func store(_ credentials: AccountCredentials, access: AccessToken) {
        self.credentials = credentials
        self.access = access
        if let data = try? JSONEncoder().encode(credentials) { Keychain.save(data, for: Self.credentialsKey) }
        AppLog.netPath.info("account stored")
    }

    func signOut(reason: String) {
        credentials = nil
        access = nil
        Keychain.delete(Self.credentialsKey)
        AppLog.netPath.info("account signed-out reason=\(reason)")
        if let onSignedOut { Task { @MainActor in onSignedOut() } }
    }
}
