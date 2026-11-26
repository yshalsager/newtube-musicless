import MusiclessCore
import SwiftUI
import UIKit

/// The orientation lock (US-018): portrait everywhere, landscape while the full-screen player shows.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientations: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }
}

@main
struct MusiclessApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var models = ModelStore(configuration: .app)

    static let forcesRightToLeft = ProcessInfo.processInfo.arguments.contains("--rtl")

    init() {
        // Thumbnails (PRD §8): AsyncImage reads through URLSession.shared, so its cache is this one.
        URLCache.shared = URLCache(memoryCapacity: 32 << 20, diskCapacity: 256 << 20)
    }
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(models)
                .preferredColorScheme(.dark)
                // `--rtl` (debug): right-to-left layout before the Arabic strings exist (US-025).
                .modifier(ForcedRightToLeft(on: Self.forcesRightToLeft))
        }
        .onChange(of: scenePhase) { _, phase in
            // `appState=` on playback log lines (the locked screen is `.background`).
            AppLog.player.info("scenePhase=\(phase)")
            if phase != .inactive { AppActivity.set(background: phase == .background) }
        }
    }
}

/// Only with `--rtl`: otherwise the system's own direction (Arabic is right-to-left) stays.
struct ForcedRightToLeft: ViewModifier {
    let on: Bool

    func body(content: Content) -> some View {
        if on { content.environment(\.layoutDirection, .rightToLeft) } else { content }
    }
}
