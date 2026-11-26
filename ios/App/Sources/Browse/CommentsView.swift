import SwiftUI
import YouTubeEngine

/// A paged list of comments: the top comments, or one comment's replies (US-026, read-only).
@MainActor @Observable
final class CommentsModel {
    private(set) var comments: [Comment] = []
    private(set) var continuation: String?
    private(set) var loading = false
    private(set) var failed = false
    @ObservationIgnored private let first: String
    @ObservationIgnored private let parentID: String?
    @ObservationIgnored private let browse: BrowseClient
    @ObservationIgnored private var started = false

    init(token: String, parentID: String? = nil, browse: BrowseClient = PlaybackServices.shared.browse) {
        first = token
        self.parentID = parentID
        self.browse = browse
    }

    func load() async {
        guard !started else { return }
        started = true
        await fetch(first)
    }

    func loadMore() async {
        guard let continuation, !loading else { return }
        await fetch(continuation)
    }

    func retry() async {
        failed = false
        await fetch(continuation ?? first)
    }

    private func fetch(_ token: String) async {
        loading = true
        defer { loading = false }
        do {
            let page = try await browse.comments(token, parentID: parentID)
            let known = Set(comments.map(\.id))
            comments += page.comments.filter { !known.contains($0.id) }
            continuation = page.continuation
        } catch {
            AppLog.netPath.info("browse comments failed error=\(error)")
            failed = true
        }
    }
}

/// The comments sheet: top comments; a comment's replies open on their own page.
struct CommentsSheet: View {
    let token: String
    let count: String?
    @Environment(\.dismiss) private var dismiss
    @State private var model: CommentsModel

    init(token: String, count: String?) {
        self.token = token
        self.count = count
        _model = State(initialValue: CommentsModel(token: token))
    }

    var body: some View {
        NavigationStack {
            CommentList(model: model)
                .navigationTitle(count.map { String(localized: "Comments · \($0)") } ?? String(localized: "Comments"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .navigationDestination(for: Comment.ID.self) { id in
                    if let comment = model.comments.first(where: { $0.id == id }), let token = comment.repliesToken {
                        RepliesView(parent: comment, token: token)
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct RepliesView: View {
    let parent: Comment
    @State private var model: CommentsModel

    init(parent: Comment, token: String) {
        self.parent = parent
        _model = State(initialValue: CommentsModel(token: token, parentID: parent.id))
    }

    var body: some View {
        CommentList(model: model, header: parent)
            .navigationTitle("Replies")
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct CommentList: View {
    let model: CommentsModel
    var header: Comment?

    var body: some View {
        List {
            if let header {
                CommentRow(comment: header, showsReplies: false)
                    .listRowBackground(Color(white: 0.12))
            }
            ForEach(model.comments) { comment in
                CommentRow(comment: comment, showsReplies: header == nil)
                    .onAppear { if comment.id == model.comments.last?.id { Task { await model.loadMore() } } }
            }
            if model.loading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            } else if model.failed {
                Button("Couldn't load comments. Try again") { Task { await model.retry() } }
                    .font(.footnote)
            }
        }
        .listStyle(.plain)
        .task { await model.load() }
        .overlay {
            if !model.loading, !model.failed, model.comments.isEmpty, header == nil {
                ContentUnavailableView("No comments", systemImage: "text.bubble")
            }
        }
    }
}

struct CommentRow: View {
    let comment: Comment
    let showsReplies: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Thumbnail(url: comment.avatar, round: true).frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 4) {
                if let pinned = comment.pinned {
                    Label(pinned, systemImage: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                }
                Text([comment.author, comment.published].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(comment.text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                HStack(spacing: 16) {
                    if let likes = comment.likes, !likes.isEmpty {
                        Label(likes, systemImage: "hand.thumbsup").font(.caption).foregroundStyle(.secondary)
                    }
                    if showsReplies, comment.repliesToken != nil, comment.replyCount > 0 {
                        NavigationLink(value: comment.id) {
                            // One key with plural forms (Android's mobile_comments_replies: six in Arabic).
                            Text("\(comment.replyCount) replies")
                                .font(.caption.weight(.semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }
}
