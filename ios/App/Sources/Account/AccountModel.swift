import Foundation
import Observation
import YouTubeEngine

/// The account as the screens see it (US-022): signed out, signing in (the code to enter), or
/// signed in (the account's name and photo).
@MainActor @Observable
final class AccountModel {
    static let shared = AccountModel()

    enum State: Equatable {
        case signedOut
        case preparing
        case code(DeviceCode)
        case signedIn
        case failed(String)
    }

    private(set) var state: State
    private(set) var info: AccountInfo?
    @ObservationIgnored private var flow: Task<Void, Never>?
    @ObservationIgnored private let services = PlaybackServices.shared

    private init() {
        state = .signedOut
        Task {
            if await services.tokens.isSignedIn {
                state = .signedIn
                info = Self.cachedInfo
                await refreshInfo()
            }
            await services.tokens.setOnSignedOut { [weak self] in self?.didSignOut() }
        }
    }

    var isSignedIn: Bool { state == .signedIn }

    /// The device-code flow: the code, then polls every `interval` until approved or expired.
    func signIn() {
        flow?.cancel()
        state = .preparing
        flow = Task {
            do {
                let client = try await services.oauth.clientData()
                let code = try await services.oauth.deviceCode(client: client, deviceID: Self.deviceID)
                guard !Task.isCancelled else { return }
                state = .code(code)
                var interval = max(code.interval, 1)
                let deadline = Date().addingTimeInterval(code.expiresIn)
                while !Task.isCancelled, Date() < deadline {
                    try await Task.sleep(for: .seconds(interval))
                    do {
                        let (credentials, access) = try await services.oauth.poll(code, client: client)
                        await services.tokens.store(credentials, access: access)
                        state = .signedIn
                        await refreshInfo()
                        return
                    } catch OAuthError.pending {
                        continue
                    } catch OAuthError.slowDown {
                        interval += 5
                    } catch let error as URLError {
                        // Away in Safari, the app's network can drop; the code stays valid.
                        AppLog.netPath.info("oauth poll failed, retrying code=\(error.code.rawValue)")
                    }
                }
                if !Task.isCancelled { state = .failed(String(localized: "The code expired. Try again.")) }
            } catch is CancellationError {
            } catch OAuthError.denied {
                state = .failed(String(localized: "Sign-in was declined."))
            } catch {
                AppLog.netPath.info("oauth sign-in failed error=\(error)")
                state = .failed(String(localized: "Couldn't sign in. Check your connection and try again."))
            }
        }
    }

    func cancelSignIn() {
        flow?.cancel()
        flow = nil
        if state != .signedIn { state = .signedOut }
    }

    func signOut() {
        Task { await services.tokens.signOut(reason: "user") }
    }

    private func didSignOut() {
        state = .signedOut
        info = nil
        Self.cachedInfo = nil
    }

    private func refreshInfo() async {
        guard let account = try? await services.browse.account() else { return }
        info = account
        Self.cachedInfo = account
    }

    /// MediaServiceData.getDeviceId: one random id per install.
    private static var deviceID: String {
        if let id = UserDefaults.standard.string(forKey: "oauthDeviceID") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "oauthDeviceID")
        return id
    }

    /// The name and photo, for the next launch's first frame (not a secret: no token, no e-mail).
    private static var cachedInfo: AccountInfo? {
        get {
            UserDefaults.standard.data(forKey: "accountInfo").flatMap { try? JSONDecoder().decode(AccountInfo.self, from: $0) }
        }
        set {
            var stored = newValue
            stored?.byline = nil
            UserDefaults.standard.set(stored.flatMap { try? JSONEncoder().encode($0) }, forKey: "accountInfo")
        }
    }
}
