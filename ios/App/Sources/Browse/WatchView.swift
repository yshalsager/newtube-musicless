import SwiftUI
import YouTubeEngine

/// What the watch page knows about its video, from `/next` (US-020), and the related list with
/// the phone's list rules.
@MainActor @Observable
final class WatchModel {
    let videoID: String
    private(set) var next: WatchNext?
    private(set) var failed = false
    private(set) var related = FeedList()
    private(set) var loadingMore = false
    @ObservationIgnored private let browse: BrowseClient

    init(videoID: String, browse: BrowseClient = PlaybackServices.shared.browse) {
        self.videoID = videoID
        self.browse = browse
    }

    func load() async {
        guard next == nil else { return }
        failed = false
        do {
            let next = try await browse.next(videoID: videoID)
            self.next = next
            related = FeedList()
            related.userAskedForMore()
            related.append(next.related)
            if related.takeTopUp() { await loadMore(force: true) }
        } catch {
            AppLog.netPath.info("browse next failed video=\(videoID) error=\(error)")
            failed = true
        }
    }

    func loadMore(force: Bool = false) async {
        guard !loadingMore, force || related.endCameIntoView(), let token = related.continuation else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await browse.continueNext(token) else { return }
        related.append(page)
        if related.takeTopUp() {
            loadingMore = false
            await loadMore(force: true)
        }
    }
}

/// The watch page (US-020): the player on top; under it the title, views and date, the channel
/// (tappable), an expandable description, and "Up next" when the setting shows it (hidden by
/// default, as in the musicless fork). A video that ends stays paused (PLAYBACK_MODE_PAUSE).
struct WatchView: View {
    let player: PlayerModel
    @Binding var path: [BrowseRoute]
    @State private var model: WatchModel
    @State private var descriptionExpanded = false
    /// The comments token while the comments sheet shows.
    @State private var comments: String?
    @State private var choosingQuality = false
    @State private var downloadStarted = false
    private let settings = AppSettings.shared

    init(videoID: String, player: PlayerModel, path: Binding<[BrowseRoute]>) {
        self.player = player
        _path = path
        _model = State(initialValue: WatchModel(videoID: videoID))
    }

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(player: player, thumbnail: URL(string: "https://i.ytimg.com/vi/\(model.videoID)/hqdefault.jpg"))
            List {
                details
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 4, trailing: 16))
                if settings.showUpNext { upNext }
            }
            .listStyle(.plain)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(player.fullScreen ? .hidden : .visible, for: .navigationBar)
        .task {
            // The page plays its own video; coming back to a page whose video still plays keeps it.
            if player.videoID != model.videoID { await player.play(model.videoID, resume: true) }
        }
        .task { await model.load() }
        .fullScreenCover(isPresented: Binding(get: { player.fullScreen }, set: { player.fullScreen = $0 })) {
            if let layer = player.layer { FullScreenVideo(watch: player, layer: layer) }
        }
        .onChange(of: player.fullScreen) { _, on in FullScreenVideo.rotate(on ? .landscape : .portrait) }
        .sheet(item: Binding(get: { comments.map(CommentsToken.init) }, set: { comments = $0?.id })) { token in
            CommentsSheet(token: token.id, count: model.next?.commentCount)
        }
        .alert("Download started", isPresented: $downloadStarted) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Follow it in You → Downloads. The file also appears in Files on this iPhone.")
        }
        .onAppear {
            // `--download` (debug): download this video at the default quality once the details are in.
            if ProcessInfo.processInfo.arguments.contains("--download") {
                Task {
                    while model.next == nil { try? await Task.sleep(for: .milliseconds(200)) }
                    if let next = model.next { startDownload(next, option: nil) }
                }
            }
            // `--comments` (debug): the comments sheet once the details are in.
            if ProcessInfo.processInfo.arguments.contains("--comments") {
                Task {
                    while model.next == nil { try? await Task.sleep(for: .milliseconds(200)) }
                    comments = model.next?.commentsToken
                }
            }
        }
    }

    @ViewBuilder private var details: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.next?.title ?? player.titleIfResolved(model.videoID) ?? " ")
                .font(.title3.weight(.semibold))
                .lineLimit(descriptionExpanded ? nil : 3)
                .redacted(reason: model.next == nil && player.titleIfResolved(model.videoID) == nil ? .placeholder : [])
            if let next = model.next {
                let line = [next.shortViews ?? next.views, next.age ?? next.published].compactMap { $0 }.joined(separator: " · ")
                if !line.isEmpty { Text(line).font(.footnote).foregroundStyle(.secondary) }
                channelRow(next)
                HStack(spacing: 10) {
                    downloadButton(next)
                    watchLaterButton
                }
                description(next)
                commentsRow(next)
            } else if model.failed {
                Button("Couldn't load the details. Try again") { Task { await model.load() } }
                    .font(.footnote)
            } else {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder private func channelRow(_ next: WatchNext) -> some View {
        if let channel = next.channel {
            Button {
                if let id = next.channelID { path.append(.channel(id: id, title: channel)) }
            } label: {
                HStack(spacing: 12) {
                    Thumbnail(url: next.channelAvatar, round: true).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(channel).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        if let subscribers = next.subscribers {
                            Text(subscribers).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    if next.channelID != nil { Image(systemName: "chevron.forward").font(.footnote).foregroundStyle(.tertiary) }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([channel, next.subscribers].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Opens the channel")
        }
    }

    @ViewBuilder private func description(_ next: WatchNext) -> some View {
        let text = next.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !text.isEmpty || next.published != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let published = next.published, descriptionExpanded {
                    Text([published, next.views, next.likes.map { String(localized: "\($0) likes") }].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption.weight(.semibold))
                }
                if !text.isEmpty {
                    Text(text)
                        .font(.footnote)
                        .lineLimit(descriptionExpanded ? nil : 3)
                        .textSelection(.enabled)
                }
                Text(descriptionExpanded ? "Show less" : "Show more")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { descriptionExpanded.toggle() } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(descriptionExpanded ? "Collapses the description" : "Expands the description")
        }
    }

    /// Download (US-028): pick a quality (the player's list), then it runs from You → Downloads.
    @ViewBuilder private func downloadButton(_ next: WatchNext) -> some View {
        Button { choosingQuality = true } label: {
            Label(AppSettings.shared.removeMusic ? String(localized: "Download without music") : String(localized: "Download"),
                  systemImage: "arrow.down.circle")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .confirmationDialog("Quality", isPresented: $choosingQuality, titleVisibility: .visible) {
            ForEach(player.videoID == model.videoID ? player.qualities : []) { option in
                Button(option.label) { startDownload(next, option: option) }
            }
            if player.videoID != model.videoID || player.qualities.isEmpty {
                Button("Best") { startDownload(next, option: nil) }
            }
        }
    }

    /// Watch later (signed in): saves the video, or removes it when it's saved.
    @ViewBuilder private var watchLaterButton: some View {
        if AccountModel.shared.isSignedIn {
            let watchLater = WatchLater.shared
            let saved = watchLater.isSaved(model.videoID)
            Button { Task { await watchLater.toggle(model.videoID) } } label: {
                Label(saved ? String(localized: "Saved") : String(localized: "Watch later"),
                      systemImage: saved ? "checkmark.circle.fill" : "clock.badge.plus")
                    .font(.subheadline.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .disabled(watchLater.pending.contains(model.videoID))
            .accessibilityHint(saved ? Text("Removes it from Watch later") : Text("Saves it to Watch later"))
            .sensoryFeedback(.success, trigger: watchLater.changes)
            .sensoryFeedback(.error, trigger: watchLater.failures)
        }
    }

    private func startDownload(_ next: WatchNext, option: VideoOption?) {
        DownloadStore.shared.start(videoID: model.videoID, title: next.title, author: next.channel ?? "",
                                   thumbnail: URL(string: "https://i.ytimg.com/vi/\(model.videoID)/hqdefault.jpg"), option: option)
        downloadStarted = true
    }

    /// The comments (US-026): a row that opens them in a sheet.
    @ViewBuilder private func commentsRow(_ next: WatchNext) -> some View {
        if let token = next.commentsToken {
            Button { comments = token } label: {
                HStack {
                    Label(next.commentCount.map { String(localized: "Comments · \($0)") } ?? String(localized: "Comments"),
                          systemImage: "text.bubble")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Image(systemName: "chevron.up").font(.footnote).foregroundStyle(.tertiary)
                }
                .padding(12)
                .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var upNext: some View {
        Section {
            ForEach(model.related.items) { item in
                Button { path.append(BrowseRoute(item)) } label: {
                    if item.kind == .channel { ChannelRow(item: item) } else { FeedCard(item: item) }
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 12, trailing: 16))
                .onAppear {
                    if item.id == model.related.items.last?.id { Task { await model.loadMore() } }
                }
            }
            if model.loadingMore {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            }
        } header: {
            if !model.related.items.isEmpty {
                Text("Up next").font(.headline).foregroundStyle(.primary)
            }
        }
    }
}

struct CommentsToken: Identifiable {
    let id: String
}
