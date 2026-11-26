import SwiftUI
import YouTubeEngine

/// A signed-in feed with the phone's list rules and paging (US-023).
@MainActor @Observable
final class FeedModel {
    enum Phase: Equatable { case idle, loading, loaded, failed }

    let feed: Feed
    private(set) var phase: Phase = .idle
    private(set) var list = FeedList()
    private(set) var loadingMore = false
    @ObservationIgnored private let browse: BrowseClient
    @ObservationIgnored private var generation = 0

    init(feed: Feed, browse: BrowseClient = PlaybackServices.shared.browse) {
        self.feed = feed
        self.browse = browse
    }

    func load(force: Bool = false) async {
        guard force || phase == .idle || phase == .failed else { return }
        generation += 1
        let generation = generation
        if phase != .loaded { phase = .loading }
        do {
            let page = try await browse.feed(feed)
            guard generation == self.generation else { return }
            var list = FeedList()
            list.userAskedForMore()
            list.append(page)
            self.list = list
            phase = .loaded
            if self.list.takeTopUp() { await loadMore(force: true) }
        } catch {
            guard generation == self.generation else { return }
            AppLog.netPath.info("browse feed failed feed=\(feed.rawValue) error=\(error)")
            if phase != .loaded { phase = .failed }
        }
    }

    func loadMore(force: Bool = false) async {
        guard phase == .loaded, !loadingMore, force || list.endCameIntoView(), let token = list.continuation else { return }
        let generation = generation
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await browse.continueBrowse(token), generation == self.generation else { return }
        list.append(page)
        if list.takeTopUp() {
            loadingMore = false
            await loadMore(force: true)
        }
    }

    func reset() {
        generation += 1
        list = FeedList()
        phase = .idle
    }
}

/// Subscriptions (the first tab), History, or Home (off by default). Signed out, a sign-in prompt.
struct FeedView: View {
    let title: LocalizedStringKey
    let systemImage: String
    @State var model: FeedModel
    let account: AccountModel
    @Binding var path: [BrowseRoute]
    let destination: (BrowseRoute) -> AnyView
    @State private var signingIn = false

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .navigationDestination(for: BrowseRoute.self) { destination($0) }
        }
        .task(id: account.isSignedIn) {
            if account.isSignedIn { await model.load() } else { model.reset() }
        }
        // History changes with every video watched: fresh each time its tab comes back.
        .onAppear {
            if model.feed == .history, account.isSignedIn, model.phase == .loaded { Task { await model.load(force: true) } }
        }
        .sheet(isPresented: $signingIn) { SignInView(account: account) }
    }

    @ViewBuilder private var content: some View {
        if !account.isSignedIn {
            ContentUnavailableView {
                Label(title, systemImage: systemImage)
            } description: {
                Text(model.feed == .history ? "Sign in to see the videos you've watched." : "Sign in to see videos from the channels you follow.")
            } actions: {
                Button("Sign in") { signingIn = true }.buttonStyle(.borderedProminent)
            }
        } else {
            switch model.phase {
            case .idle, .loading:
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed:
                ContentUnavailableView {
                    Label("Couldn't load the feed", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("Try again") { Task { await model.load(force: true) } }
                }
            case .loaded:
                if model.list.items.isEmpty {
                    ContentUnavailableView(title, systemImage: systemImage,
                                           description: Text(model.feed == .history ? "Videos you watch appear here." : "Nothing here yet."))
                } else {
                    List {
                        FeedRowsSection(items: model.list.items, loadingMore: model.loadingMore, path: $path) {
                            Task { await model.loadMore() }
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await model.load(force: true) }
                }
            }
        }
    }
}
