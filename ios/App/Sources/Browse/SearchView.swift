import SwiftUI
import YouTubeEngine

/// Where a list's tap goes. The watch page (US-020) and the channel page (US-021) take these over.
enum BrowseRoute: Hashable {
    case watch(videoID: String)
    case channel(id: String, title: String)
    case playlist(id: String, title: String)

    init(_ item: FeedItem) {
        switch item.kind {
        case .channel: self = .channel(id: item.id, title: item.title)
        case .playlist: self = .playlist(id: item.id, title: item.title)
        default: self = .watch(videoID: item.id)
        }
    }
}

/// The Search tab (US-019): the field, recent searches while nothing is searched, results as cards
/// with paging. Android's MobileSearchActivity, with the system search field.
struct SearchView: View {
    @Bindable var model: SearchModel
    @Binding var path: [BrowseRoute]
    let destination: (BrowseRoute) -> AnyView

    var body: some View {
        NavigationStack(path: $path) {
            content
                .navigationTitle("Search")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $model.text, placement: .navigationBarDrawer(displayMode: .always), prompt: Text("Search YouTube"))
                .searchSuggestions { suggestions }
                .onSubmit(of: .search) { Task { await model.submit() } }
                .onChange(of: model.text) { _, text in
                    if text.isEmpty, model.submitted != nil { model.reset() }
                }
                .navigationDestination(for: BrowseRoute.self) { destination($0) }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.phase {
        case .idle:
            RecentSearches(history: model.history) { query in Task { await model.submit(query) } }
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Search failed", systemImage: "exclamationmark.magnifyingglass")
            } description: {
                Text(message)
            } actions: {
                Button("Try again") { Task { await model.retry() } }
            }
        case .loaded:
            if model.items.isEmpty, !model.loadingMore {
                ContentUnavailableView.search(text: model.submitted ?? "")
            } else {
                results
            }
        }
    }

    private var results: some View {
        List {
            ForEach(model.items) { item in
                // A button, not a NavigationLink: no disclosure chevron beside a full-width card.
                Button { path.append(route(item)) } label: {
                    if item.kind == .channel { ChannelRow(item: item) } else { FeedCard(item: item) }
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                .onAppear {
                    if item.id == model.items.last?.id { Task { await model.loadMore() } }
                }
            }
            if model.loadingMore {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .scrollDismissesKeyboard(.immediately)
    }

    /// Recent searches matching what is being typed. None once the field holds the submitted query:
    /// a search adds its query to the history first, so it would match itself, and while the field
    /// stays active the suggestions cover the results.
    @ViewBuilder private var suggestions: some View {
        if model.text != model.submitted {
            ForEach(model.history.matching(model.text), id: \.self) { query in
                Button {
                    // The keyboard goes too, as it does for the keyboard's Search key.
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                    Task { await model.submit(query) }
                } label: {
                    Label(query, systemImage: "clock.arrow.circlepath")
                }
                .foregroundStyle(.primary)
            }
        }
    }

    private func route(_ item: FeedItem) -> BrowseRoute { BrowseRoute(item) }
}

/// Recent searches, newest first: tap to search again, swipe to remove one, or clear them all.
struct RecentSearches: View {
    let history: SearchHistory
    let search: (String) -> Void

    var body: some View {
        if history.entries.isEmpty {
            ContentUnavailableView {
                Label("Search YouTube", systemImage: "magnifyingglass")
            } description: {
                Text("Find a video to watch without its music.")
            }
        } else {
            List {
                Section {
                    ForEach(history.entries, id: \.self) { query in
                        Button { search(query) } label: {
                            Label {
                                Text(query).foregroundStyle(Color.primary)
                            } icon: {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(Color.secondary)
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { history.remove(query) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("Recent searches")
                } footer: {
                    Button("Clear search history", role: .destructive) { history.clear() }
                        .font(.footnote)
                        .padding(.top, 8)
                }
            }
            .listStyle(.insetGrouped)
        }
    }
}
