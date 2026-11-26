import Foundation
import Observation
import YouTubeEngine

/// Search history, on this phone only (US-019): newest first, each query once (ignoring case),
/// at most 50, in Application Support. Clearable as a whole or one entry at a time.
@MainActor @Observable
final class SearchHistory {
    static let limit = 50
    private(set) var entries: [String] = []
    @ObservationIgnored private let url: URL?

    init(url: URL? = URL.applicationSupportDirectory.appending(path: "search-history.json")) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([String].self, from: data) {
            entries = saved
        }
    }

    func add(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        entries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        entries.insert(trimmed, at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        save()
    }

    func remove(_ query: String) {
        entries.removeAll { $0 == query }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    /// Entries starting with what's typed (all of them for an empty field), for the suggestions.
    func matching(_ prefix: String, limit: Int = 8) -> [String] {
        let typed = prefix.trimmingCharacters(in: .whitespaces)
        let matches = typed.isEmpty ? entries : entries.filter {
            $0.range(of: typed, options: [.caseInsensitive, .anchored, .diacriticInsensitive]) != nil
        }
        return Array(matches.prefix(limit))
    }

    private func save() {
        guard let url else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(entries).write(to: url, options: .atomic)
    }
}

/// The Search tab's state (US-019): the field, the submitted query and its paged results, with
/// Android's list rules (`FeedList`: no Shorts, channels first, top-up).
@MainActor @Observable
final class SearchModel {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    var text = ""
    private(set) var submitted: String?
    private(set) var phase: Phase = .idle
    private(set) var list = FeedList()
    private(set) var loadingMore = false
    let history: SearchHistory
    @ObservationIgnored private let browse: BrowseClient
    /// Bumped by every new search, so a late page of an old query is dropped.
    @ObservationIgnored private var generation = 0

    init(browse: BrowseClient, history: SearchHistory = SearchHistory()) {
        self.browse = browse
        self.history = history
    }

    var items: [FeedItem] { list.items }

    func submit(_ query: String? = nil) async {
        let query = (query ?? text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        text = query
        history.add(query)
        generation += 1
        let generation = generation
        submitted = query
        list = FeedList()
        list.userAskedForMore()
        phase = .loading
        loadingMore = false
        do {
            let page = try await browse.search(query)
            guard generation == self.generation else { return }
            list.append(page)
            phase = .loaded
            await topUp(generation)
        } catch {
            guard generation == self.generation else { return }
            AppLog.netPath.info("browse search failed error=\(error)")
            phase = .failed(Self.message(error))
        }
    }

    /// The last row came into view: the next page, if there is one (and, for a short list, if the
    /// top-up budget allows: `FeedList.endCameIntoView`).
    func loadMore() async {
        guard phase == .loaded, !loadingMore, list.endCameIntoView() else { return }
        await nextPage(generation)
    }

    func retry() async {
        guard let submitted else { return }
        await submit(submitted)
    }

    /// Back to the history (the field was cleared).
    func reset() {
        generation += 1
        submitted = nil
        list = FeedList()
        phase = .idle
        loadingMore = false
    }

    private func nextPage(_ generation: Int) async {
        guard let token = list.continuation else { return }
        loadingMore = true
        defer { if generation == self.generation { loadingMore = false } }
        do {
            let page = try await browse.continueSearch(token)
            guard generation == self.generation else { return }
            list.append(page)
        } catch {
            AppLog.netPath.info("browse search-continuation failed error=\(error)")
            return
        }
        await topUp(generation)
    }

    /// FilteredPageTopUp: a page that left the list short (its Shorts dropped) asks for the next.
    private func topUp(_ generation: Int) async {
        guard generation == self.generation, list.takeTopUp() else { return }
        AppLog.netPath.info("browse search top-up kept=\(list.items.count) droppedShorts=\(list.droppedShorts)")
        await nextPage(generation)
    }

    static func message(_ error: any Error) -> String {
        if let urlError = error as? URLError, [.notConnectedToInternet, .networkConnectionLost, .timedOut].contains(urlError.code) {
            return String(localized: "Check your connection and try again.")
        }
        return String(localized: "YouTube didn't answer the search. Try again.")
    }
}
