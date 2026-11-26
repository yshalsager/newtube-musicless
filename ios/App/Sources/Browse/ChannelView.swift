import SwiftUI
import YouTubeEngine

/// A channel (US-021): the header, and its sections as chips (Android's tabs: Videos, Live,
/// Playlists, …), the selected one as full-width cards with paging. Videos is selected first.
/// Sections the Shorts filter empties, and the untitled tab row, aren't shown.
@MainActor @Observable
final class ChannelModel {
    let id: String
    private(set) var page: ChannelPage?
    private(set) var failed = false
    private(set) var sections: [ChannelPage.Section] = []
    private(set) var lists: [Int: FeedList] = [:]
    private(set) var loading: Set<Int> = []
    var selected: Int?
    @ObservationIgnored private let browse: BrowseClient

    init(id: String, browse: BrowseClient = PlaybackServices.shared.browse) {
        self.id = id
        self.browse = browse
    }

    func load() async {
        guard page == nil else { return }
        failed = false
        do {
            let page = try await browse.channel(id: id)
            var lists: [Int: FeedList] = [:]
            var shown: [ChannelPage.Section] = []
            for section in page.sections where !section.title.isEmpty {
                var list = FeedList()
                list.userAskedForMore()
                list.append(section.page)
                guard !list.items.isEmpty else { continue }  // all Shorts (#63): no empty tab
                lists[section.id] = list
                shown.append(section)
            }
            self.page = page
            self.lists = lists
            sections = shown
            selected = shown.first(where: \.isUploads)?.id ?? shown.first?.id
        } catch {
            AppLog.netPath.info("browse channel failed error=\(error)")
            failed = true
        }
    }

    var items: [FeedItem] { selected.flatMap { lists[$0]?.items } ?? [] }

    func loadMore() async {
        guard let section = selected, !loading.contains(section), var list = lists[section], list.endCameIntoView(),
              let token = list.continuation else { return }
        loading.insert(section)
        defer { loading.remove(section) }
        guard let page = try? await browse.continueBrowse(token) else { return }
        list.append(page)
        lists[section] = list
    }
}

struct ChannelView: View {
    @Binding var path: [BrowseRoute]
    let title: String
    @State private var model: ChannelModel

    init(id: String, title: String, path: Binding<[BrowseRoute]>) {
        self.title = title
        _path = path
        _model = State(initialValue: ChannelModel(id: id))
    }

    var body: some View {
        List {
            header
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
            if model.sections.count > 1 {
                chips
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 8, trailing: 0))
            }
            FeedRowsSection(items: model.items, loadingMore: model.selected.map { model.loading.contains($0) } ?? false,
                            path: $path) { Task { await model.loadMore() } }
        }
        .listStyle(.plain)
        .navigationTitle(model.page?.title ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .overlay {
            if model.failed {
                ContentUnavailableView {
                    Label("Couldn't load the channel", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                }
            } else if model.page == nil {
                ProgressView()
            }
        }
    }

    @ViewBuilder private var header: some View {
        if let page = model.page {
            HStack(spacing: 14) {
                Thumbnail(url: page.avatar, round: true).frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title).font(.title3.weight(.bold)).lineLimit(2)
                    let line = [page.handle, page.subscribers].compactMap { $0 }.joined(separator: " · ")
                    if !line.isEmpty { Text(line).font(.footnote).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(model.sections) { section in
                    let selected = model.selected == section.id
                    Button { model.selected = section.id } label: {
                        Text(section.title)
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 7)
                            .foregroundStyle(selected ? Color.black : Color.primary)
                            .background(selected ? Color.white : Color(white: 0.18), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isSelected] : [])
                }
            }
            .padding(.horizontal, 16)
        }
    }
}

/// A playlist: its title and owner, then its videos with paging.
@MainActor @Observable
final class PlaylistModel {
    let id: String
    private(set) var page: PlaylistPage?
    private(set) var failed = false
    private(set) var list = FeedList()
    private(set) var loadingMore = false
    @ObservationIgnored private let browse: BrowseClient

    init(id: String, browse: BrowseClient = PlaybackServices.shared.browse) {
        self.id = id
        self.browse = browse
    }

    func load() async {
        guard page == nil else { return }
        failed = false
        do {
            let page = try await browse.playlist(id: id)
            self.page = page
            list = FeedList()
            list.userAskedForMore()
            list.append(page.page)
            noteWatchLater(page.page.items)
        } catch {
            AppLog.netPath.info("browse playlist failed error=\(error)")
            failed = true
        }
    }

    func loadMore() async {
        guard !loadingMore, list.endCameIntoView(), let token = list.continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await browse.continueBrowse(token) else { return }
        list.append(page)
        noteWatchLater(page.items)
    }

    var isWatchLater: Bool { id == BrowseClient.watchLater }

    /// The Watch later list's videos are saved (their card menus offer to remove them).
    private func noteWatchLater(_ items: [FeedItem]) {
        if isWatchLater { WatchLater.shared.noteListed(items.map(\.id)) }
    }
}

struct PlaylistView: View {
    @Binding var path: [BrowseRoute]
    let title: String
    @State private var model: PlaylistModel

    init(id: String, title: String, path: Binding<[BrowseRoute]>) {
        self.title = title
        _path = path
        _model = State(initialValue: PlaylistModel(id: id))
    }

    var body: some View {
        List {
            if let page = model.page {
                VStack(alignment: .leading, spacing: 4) {
                    Text(page.title).font(.title3.weight(.bold))
                    if let owner = page.owner { Text(owner).font(.footnote).foregroundStyle(.secondary) }
                }
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .accessibilityElement(children: .combine)
            }
            // Watch later drops a video as soon as its menu removes it.
            let items = model.isWatchLater ? model.list.items.filter { WatchLater.shared.isSaved($0.id) } : model.list.items
            FeedRowsSection(items: items, loadingMore: model.loadingMore, path: $path) { Task { await model.loadMore() } }
        }
        .listStyle(.plain)
        .navigationTitle(model.page?.title ?? title)
        .navigationBarTitleDisplayMode(.inline)
        .task { await model.load() }
        .overlay {
            if model.failed {
                ContentUnavailableView {
                    Label("Couldn't load the playlist", systemImage: "wifi.exclamationmark")
                } actions: {
                    Button("Try again") { Task { await model.load() } }
                }
            } else if model.page == nil {
                ProgressView()
            }
        }
    }
}

/// The rows of a list of cards, pushing each one's route; the last row asks for more.
struct FeedRowsSection: View {
    let items: [FeedItem]
    let loadingMore: Bool
    @Binding var path: [BrowseRoute]
    let loadMore: () -> Void

    var body: some View {
        ForEach(items) { item in
            Button { path.append(BrowseRoute(item)) } label: {
                if item.kind == .channel { ChannelRow(item: item) } else { FeedCard(item: item) }
            }
            .buttonStyle(.plain)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
            .onAppear { if item.id == items.last?.id { loadMore() } }
        }
        if loadingMore {
            ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
        }
    }
}
