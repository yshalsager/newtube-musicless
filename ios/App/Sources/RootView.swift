import MediaPipeline
import MusiclessCore
import SwiftUI
import UniformTypeIdentifiers
import YouTubeEngine

/// The app's tabs (PRD FR-18): Subscriptions first, Search, You. You holds the debug screens until
/// Settings (US-024) takes them over.
struct RootView: View {
    @Environment(ModelStore.self) private var models
    @State private var tab: Tab = .subscriptions
    @State private var openingFile = false
    @State private var path: [Route] = []
    @State private var searchPath: [BrowseRoute] = []
    @State private var subscriptionsPath: [BrowseRoute] = []
    @State private var homePath: [BrowseRoute] = []
    @State private var historyPath: [BrowseRoute] = []
    @State private var subscriptions = FeedModel(feed: .subscriptions)
    @State private var home = FeedModel(feed: .home)
    @State private var history = FeedModel(feed: .history)
    private let settings = AppSettings.shared
    @State private var search = SearchModel(browse: PlaybackServices.shared.browse)
    /// The watch screen's player; it outlives the view and stops when its route is popped.
    @State private var watch: PlayerModel?

    enum Tab: Hashable { case home, subscriptions, history, search, you }

    enum Route: Hashable {
        case probe
        /// autoStart: true = locked run, false = foreground run, nil = wait for a tap.
        case benchmark(autoStart: Bool?)
        /// US-012; `id` plays at once (from `--voices`).
        case voices(id: String?, at: Double)
        case settings
        /// A local file (US-027); `voicesOnly`: a download saved without music.
        case file(URL, voicesOnly: Bool = false)
        case downloads
        /// A list page or video opened from You (Watch later), in the You tab's own stack.
        case browse(BrowseRoute)
    }

    var body: some View {
        TabView(selection: $tab) {
            if settings.showHome {
                FeedView(title: "Home", systemImage: "house", model: home, account: AccountModel.shared, path: $homePath) {
                    AnyView(destination($0, path: $homePath))
                }
                .tabItem { Label("Home", systemImage: "house") }
                .tag(Tab.home)
            }
            FeedView(title: "Subscriptions", systemImage: "play.square.stack", model: subscriptions, account: AccountModel.shared,
                     path: $subscriptionsPath) { AnyView(destination($0, path: $subscriptionsPath)) }
                .tabItem { Label("Subscriptions", systemImage: "play.square.stack") }
                .tag(Tab.subscriptions)
            // History (signed in), a tab as on Android (MobileBrowseActivity's bottom nav).
            FeedView(title: "History", systemImage: "clock.arrow.circlepath", model: history, account: AccountModel.shared,
                     path: $historyPath) { AnyView(destination($0, path: $historyPath)) }
                .tabItem { Label("History", systemImage: "clock.arrow.circlepath") }
                .tag(Tab.history)
            SearchView(model: search, path: $searchPath) { AnyView(destination($0, path: $searchPath)) }
                .tabItem { Label("Search", systemImage: "magnifyingglass") }
                .tag(Tab.search)
            you
                .tabItem { Label("You", systemImage: "person.crop.circle") }
                .tag(Tab.you)
        }
        .onAppear(perform: launch)
        // "Open in" from Files and other apps (CFBundleDocumentTypes), and the document picker.
        .onOpenURL { url in
            guard url.isFileURL else { return }
            AppLog.player.info("local open-in file=\(url.pathExtension)")
            tab = .you
            path = [.file(url)]
        }
        .fileImporter(isPresented: $openingFile, allowedContentTypes: [.movie, .audio]) { result in
            if case .success(let url) = result {
                tab = .you
                path.append(.file(url))
            }
        }
        .onChange(of: path) { _, _ in stopPlayerIfHidden() }
        .onChange(of: searchPath) { _, _ in stopPlayerIfHidden() }
        .onChange(of: subscriptionsPath) { _, _ in stopPlayerIfHidden() }
        .onChange(of: homePath) { _, _ in stopPlayerIfHidden() }
        .onChange(of: historyPath) { _, _ in stopPlayerIfHidden() }
        .onChange(of: models.status) { _, status in
            AppLog.musicless.info("Model status \(status.logValue)")
        }
    }

    /// A list's tap: the watch page (US-020), the channel and playlist pages (US-021).
    @ViewBuilder private func destination(_ route: BrowseRoute, path: Binding<[BrowseRoute]>) -> some View {
        switch route {
        case .watch(let videoID):
            if let watch { WatchView(videoID: videoID, player: watch, path: path) }
        case .channel(let id, let title):
            ChannelView(id: id, title: title, path: path)
        case .playlist(let id, let title):
            PlaylistView(id: id, title: title, path: path)
        }
    }

    private func stopPlayerIfHidden() {
        let showsVoices = path.contains {
            switch $0 {
            case .voices, .file: true
            default: false
            }
        }
        let showsWatch = [searchPath, subscriptionsPath, homePath, historyPath, youBrowsePath.wrappedValue].contains { stack in
            stack.contains { if case .watch = $0 { true } else { false } }
        }
        if !showsVoices, !showsWatch, let watch, watch.isActive { Task { await watch.stop(reason: "left the screen") } }
    }

    /// The You tab's list pages, seen as browse routes (they follow its own screens in the stack).
    private var youBrowsePath: Binding<[BrowseRoute]> {
        Binding(get: { path.compactMap { if case .browse(let route) = $0 { route } else { nil } } },
                set: { routes in
                    path = path.filter { if case .browse = $0 { false } else { true } } + routes.map(Route.browse)
                })
    }

    private var you: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    AccountRow(account: AccountModel.shared)
                }
                if AccountModel.shared.isSignedIn {
                    Section {
                        NavigationLink(value: Route.browse(.playlist(id: BrowseClient.watchLater, title: String(localized: "Watch later")))) {
                            Label("Watch later", systemImage: "clock")
                        }
                    }
                }
                Section {
                    NavigationLink(value: Route.downloads) {
                        Label("Downloads", systemImage: "arrow.down.circle")
                    }
                    Button { openingFile = true } label: {
                        Label("Open a file", systemImage: "folder")
                    }
                }
                Section {
                    NavigationLink(value: Route.settings) {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .navigationTitle("You")
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .probe: DeviceProbeView()
                case .benchmark(let autoStart):
                    BenchmarkView(benchmark: SeparationBenchmark(models: models), autoStart: autoStart)
                case .settings:
                    SettingsView(player: watch)
                case .file(let url, let voicesOnly):
                    if let watch { LocalFileView(url: url, voicesOnly: voicesOnly, player: watch) }
                case .downloads:
                    DownloadsView(path: $path)
                case .browse(let route):
                    destination(route, path: youBrowsePath)
                case .voices(let id, let at):
                    if let watch {
                        let arguments = ProcessInfo.processInfo.arguments
                        WatchDebugView(watch: watch, autoPlay: id.map { ($0, at) },
                                       seekCheck: arguments.contains("--seek-check"),
                                       backgroundTest: arguments.contains("--background-test"),
                                       qualityCheck: arguments.contains("--quality-check"),
                                       wallCheck: arguments.contains("--wall-check"),
                                       systemCheck: arguments.contains("--system-check"))
                    }
                }
            }
        }
    }

    /// Launch flags open their screen (on the You tab) or start their check.
    private func launch() {
        if watch == nil { watch = PlayerModel(models: models) }
        PlaybackServices.shared.warmUp()
        AppLog.probe.info("launch version=\(BuildInfo.version) build=\(BuildInfo.build) commit=\(BuildInfo.commit)")
        // `--run-probe` opens the probe at launch, so it can be captured without touching the phone:
        // xcrun devicectl device process launch --device "$DEVICE_ID" --console <bundle id> --run-probe
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--run-probe"), path.isEmpty {
            path = [.probe]
        }
        // `--benchmark` / `--benchmark-locked` start the US-006 benchmark at launch (add
        // `--console-log` to a Release build to see its lines in `devicectl … --console`).
        if path.isEmpty, arguments.contains("--benchmark") || arguments.contains("--benchmark-locked") {
            path = [.benchmark(autoStart: arguments.contains("--benchmark-locked"))]
        }
        // `--player-check` asks VISIONOS for five ordinary videos with the real and a -1 timestamp (US-008).
        if arguments.contains("--player-check") { Task { await PlayerCheckRunner.run() } }
        if arguments.contains("--resolve-check") { Task { await PlayerCheckRunner.runUS009(record: false) } }
        if arguments.contains("--record-answers") { Task { await PlayerCheckRunner.runUS009(record: true) } }
        if arguments.contains("--fetch-check") { Task { await FetchCheckRunner.run() } }
        // `--account-lists-check`: History, Watch later and Subscriptions, read only: counts and red bars.
        if arguments.contains("--account-lists-check") {
            Task {
                let browse = PlaybackServices.shared.browse
                func line(_ name: String, _ items: [FeedItem], more: Bool) {
                    let watched = items.compactMap(\.percentWatched)
                    AppLog.netPath.info("account-lists \(name) items=\(items.count) watched=\(watched.count) "
                                        + "percents=\(watched.prefix(8)) continuation=\(more ? "y" : "n")")
                }
                do { let page = try await browse.feed(.history); line("history", page.items, more: page.continuation != nil) }
                catch { AppLog.netPath.info("account-lists history failed error=\(error)") }
                do { let page = try await browse.playlist(id: BrowseClient.watchLater); line("watch-later", page.page.items, more: page.page.continuation != nil) }
                catch { AppLog.netPath.info("account-lists watch-later failed error=\(error)") }
                do { let page = try await browse.feed(.subscriptions); line("subscriptions", page.items, more: page.continuation != nil) }
                catch { AppLog.netPath.info("account-lists subscriptions failed error=\(error)") }
            }
        }
        // `--history-probe <id>`: the account-bound /player variants for watch history, read only.
        if let index = arguments.firstIndex(of: "--history-probe"), arguments.indices.contains(index + 1) {
            let videoID = arguments[index + 1]
            Task {
                let services = PlaybackServices.shared
                guard let authorization = await services.tokens.authorization() else {
                    AppLog.netPath.info("history-probe signed-out")
                    return
                }
                await services.sources.historyProbe(videoID: videoID, authorization: authorization)
            }
        }
        // `--sync-check [<id>] [--sync-seconds <s>]`: beep and flash timing of a sync test video (US-013).
        if let index = arguments.firstIndex(of: "--sync-check") {
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
            let seconds = arguments.firstIndex(of: "--sync-seconds")
                .flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 40
            Task { await SyncCheck.run(videoID: next.hasPrefix("--") || next.isEmpty ? nil : next, seconds: seconds) }
        }
        // `--solver-check`: the challenge solver's cold and warm speed on this phone (US-016).
        if arguments.contains("--solver-check") { Task { await SolverCheck.run() } }
        // `--delay-check [<id> …]`: AAC vs Opus delay by cross-correlation (US-013); presets by default.
        if let index = arguments.firstIndex(of: "--delay-check") {
            let ids = arguments[(index + 1)...].prefix { !$0.hasPrefix("--") }
            let seconds = arguments.firstIndex(of: "--sync-seconds")
                .flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil } ?? 30
            Task { await SyncCheck.runDelay(videoIDs: ids.isEmpty ? PlayerModel.presets.map(\.id) + SyncCheck.candidates : Array(ids),
                                            seconds: seconds) }
        }
        // `--voices [<id>] [--voices-at <seconds>]` plays a video's voices at launch (US-012).
        if path.isEmpty, arguments.contains("--wall-check") { path = [.voices(id: nil, at: 0)] }
        if path.isEmpty, let index = arguments.firstIndex(of: "--voices") {
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
            let id = next.hasPrefix("--") || next.isEmpty ? PlayerModel.presets[0].id : next
            let at = arguments.firstIndex(of: "--voices-at").flatMap { arguments.indices.contains($0 + 1) ? Double(arguments[$0 + 1]) : nil }
            path = [.voices(id: id, at: at ?? 0)]
        }
        if arguments.contains("--record-media") { Task { await MediaRecorder.run() } }
        AppLog.musicless.info("Model status \(models.status.logValue)")
        // The fork's first run: the voice models download at launch while Remove music is on
        // (MobileMainApplication, MusiclessPrefs.isOn). `--download-models` forces it.
        if AppSettings.shared.removeMusic || arguments.contains("--download-models") { models.start() }
        if path.isEmpty, let index = arguments.firstIndex(of: "--search") {
            // `--search [<query>]`: the Search tab, searching at once (screenshots, phone checks).
            tab = .search
            let next = arguments.indices.contains(index + 1) ? arguments[index + 1] : ""
            if !next.isEmpty, !next.hasPrefix("--") {
                Task {
                    await search.submit(next)
                    // `--search-more`: two more pages, as two scrolls to the end would ask.
                    guard arguments.contains("--search-more") else { return }
                    for _ in 0..<2 { await search.loadMore() }
                    AppLog.netPath.info("browse search-more done kept=\(search.items.count) droppedShorts=\(search.list.droppedShorts) "
                                        + "more=\(search.list.hasMore ? "y" : "n")")
                }
            }
        }
        // `--channel <id>` / `--playlist <id>`: those pages (US-021), on the Search tab's stack.
        for (flag, route) in [("--channel", { BrowseRoute.channel(id: $0, title: "") }),
                              ("--playlist", { BrowseRoute.playlist(id: $0, title: "") })] as [(String, (String) -> BrowseRoute)] {
            if path.isEmpty, let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) {
                tab = .search
                searchPath = [route(arguments[index + 1])]
            }
        }
        // `--watch <id>`: the watch page for a video (US-020), on the Search tab's stack.
        if path.isEmpty, let index = arguments.firstIndex(of: "--watch"), arguments.indices.contains(index + 1) {
            tab = .search
            searchPath = [.watch(videoID: arguments[index + 1])]
        }
        if path.isEmpty, arguments.contains("--settings") { path = [.settings] }
        if path.isEmpty, arguments.contains("--downloads") { path = [.downloads] }
        PlaybackServices.shared.models = models
        // `--file <name>` (debug): a file in the app's Documents folder (Files → On My iPhone).
        if path.isEmpty, let index = arguments.firstIndex(of: "--file"), arguments.indices.contains(index + 1) {
            path = [.file(URL.documentsDirectory.appending(path: arguments[index + 1]))]
        }
        if !path.isEmpty || arguments.contains("--sign-in") { tab = .you }
    }
}

/// The voice models' state, with Download or Retry (US-004). Settings take this over in US-024.
struct ModelStatusRow: View {
    @Environment(ModelStore.self) private var models

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice models")
                    Text(models.status.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "waveform")
            }
            Spacer()
            switch models.status {
            case .notDownloaded: Button("Download") { models.start() }
            case .failed: Button("Retry") { models.retry() }
            case .downloading: ProgressView()
            case .ready: EmptyView()
            }
        }
        .accessibilityElement(children: .combine)
    }
}
