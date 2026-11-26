import SafariServices
import SwiftUI
import YouTubeEngine

/// The sign-in sheet (US-022; PRD §4.4, Android's MobileSignInActivity): the code, a button that
/// opens yt.be/activate in Safari (inside the app), and polling that closes everything once the
/// code is approved.
struct SignInView: View {
    @Environment(\.dismiss) private var dismiss
    let account: AccountModel
    @State private var safari: URL?
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch account.state {
                case .preparing, .signedOut:
                    ProgressView("Getting a code…")
                case .code(let code):
                    instructions(code)
                case .signedIn:
                    Label("Signed in", systemImage: "checkmark.circle.fill").font(.title3).foregroundStyle(.green)
                case .failed(let message):
                    ContentUnavailableView {
                        Label("Sign-in stopped", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(message)
                    } actions: {
                        Button("Try again") { account.signIn() }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Sign in")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        account.cancelSignIn()
                        dismiss()
                    }
                }
            }
        }
        .onAppear { if account.state == .signedOut || account.isFailed { account.signIn() } }
        .onChange(of: account.state) { _, state in
            if state == .signedIn {
                safari = nil
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    dismiss()
                }
            }
        }
        .sheet(item: $safari) { url in SafariView(url: url).ignoresSafeArea() }
    }

    private func instructions(_ code: DeviceCode) -> some View {
        VStack(spacing: 20) {
            Text("Enter this code on the activation page, signed in to your Google account:")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Text(code.userCode)
                .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                .textSelection(.enabled)
                .environment(\.layoutDirection, .leftToRight)
                .accessibilityLabel(code.userCode.map(String.init).joined(separator: " "))
            Button(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = code.userCode
                copied = true
            }
            .buttonStyle(.bordered)
            // YTSignInPresenter: the code-prefilled page first, yt.be/activate as the manual way.
            Button("Continue with Google", systemImage: "safari") {
                UIPasteboard.general.string = code.userCode
                safari = URL(string: "https://youtube.com/qr/activate/" + code.userCode.replacingOccurrences(of: " ", with: "-"))
            }
            .buttonStyle(.borderedProminent)
            Button("Or open yt.be/activate and type the code") {
                UIPasteboard.general.string = code.userCode
                safari = URL(string: "https://yt.be/activate")
            }
            .font(.footnote)
            HStack(spacing: 8) {
                ProgressView()
                Text("Waiting for you to approve it…").font(.footnote).foregroundStyle(.secondary)
            }
            Text("Your account stays on this iPhone. It's used for your subscriptions and watch history, and for videos that need it.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }
}

extension AccountModel {
    var isFailed: Bool { if case .failed = state { true } else { false } }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Safari inside the app, for the activation page.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// The account row on the You tab: sign in, or who is signed in and Sign out.
struct AccountRow: View {
    let account: AccountModel
    @State private var signingIn = false
    @State private var confirmSignOut = false

    var body: some View {
        Group {
            if account.isSignedIn {
                HStack(spacing: 12) {
                    Thumbnail(url: account.info?.avatar, round: true).frame(width: 44, height: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.info?.name ?? String(localized: "Signed in")).font(.headline)
                        if let line = account.info?.byline ?? account.info?.handle {
                            Text(line).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                        .buttonStyle(.borderless)
                }
                .confirmationDialog("Sign out of this account?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                    Button("Sign out", role: .destructive) { account.signOut() }
                }
            } else {
                Button { signingIn = true } label: {
                    Label("Sign in", systemImage: "person.crop.circle.badge.plus")
                }
            }
        }
        .sheet(isPresented: $signingIn) { SignInView(account: account) }
        .onAppear {
            // `--sign-in` (debug): the sheet at launch, to see the code on the phone.
            if ProcessInfo.processInfo.arguments.contains("--sign-in"), !account.isSignedIn { signingIn = true }
        }
    }
}
