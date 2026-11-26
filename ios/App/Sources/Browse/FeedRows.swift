import SwiftUI
import YouTubeEngine

/// A thumbnail at 16:9 (or round, for a channel), from the shared URLCache (sized at launch).
struct Thumbnail: View {
    let url: URL?
    var round = false

    var body: some View {
        // The rectangle takes the offered size; the image fills it and is cropped to it (a 4:3
        // `sddefault.jpg` with letterbox bars crops to its 16:9 picture).
        Rectangle()
            .fill(Color(white: 0.16))
            .overlay {
                AsyncImage(url: url, transaction: Transaction(animation: .easeOut(duration: 0.15))) { phase in
                    if case .success(let image) = phase { image.resizable().scaledToFill() }
                }
            }
            .clipShape(round ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 12, style: .continuous)))
            .accessibilityHidden(true)
    }
}

/// A video, live or playlist result: the thumbnail across the width with its length badge, then
/// the title and "channel · views · age" (the Android phone's card, VideoCardAdapter).
struct FeedCard: View {
    let item: FeedItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay { Thumbnail(url: item.thumbnail) }
                .overlay(alignment: .bottomTrailing) { badge.padding(.horizontal, 8).padding(.bottom, watched == nil ? 8 : 11) }
                .overlay(alignment: .bottom) {
                    if let watched { WatchedBar(percent: watched) }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.horizontal, 4)
        }
        .contentShape(Rectangle())
        .contextMenu { if item.isPlayable, item.kind != .short { WatchLaterMenuItem(videoID: item.id) } }
        .onAppear { if item.isPlayable { WatchProgress.shared.noteYouTube(videoID: item.id, percent: item.percentWatched) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .accessibilityAddTraits(.isButton)
    }

    /// The red bar: this app's record of the video, else YouTube's (signed in).
    private var watched: Int? {
        guard item.isPlayable else { return nil }
        return WatchProgress.shared.barPercent(videoID: item.id, youtube: item.percentWatched)
    }

    private var subtitle: String {
        ([item.channel].compactMap { $0 } + item.details).joined(separator: " · ")
    }

    @ViewBuilder private var badge: some View {
        switch item.kind {
        case .live:
            BadgeLabel(text: String(localized: "LIVE"), background: .red)
        case .upcoming:
            BadgeLabel(text: String(localized: "Upcoming"), background: .black.opacity(0.75))
        case .playlist:
            BadgeLabel(text: item.duration ?? String(localized: "Playlist"), background: .black.opacity(0.75), systemImage: "list.bullet")
        default:
            if let duration = item.duration {
                BadgeLabel(text: duration, background: .black.opacity(0.75))
                    .environment(\.layoutDirection, .leftToRight)  // "10:35" reads the same in Arabic
            }
        }
    }

    private var accessibilityText: String {
        var parts = [item.title]
        if let channel = item.channel { parts.append(channel) }
        parts += item.details
        switch item.kind {
        case .live: parts.append(String(localized: "Live"))
        case .upcoming: parts.append(String(localized: "Upcoming"))
        case .playlist: parts.append(String(localized: "Playlist"))
        default: if let duration = item.duration { parts.append(duration) }
        }
        if let watched { parts.append(watched >= 100 ? String(localized: "Watched") : String(localized: "Watched \(watched)%")) }
        return parts.joined(separator: ", ")
    }
}

/// How much of a video was watched: YouTube's red bar along the thumbnail's bottom edge, from the
/// leading side (it mirrors in Arabic, as Android's ProgressBar does).
struct WatchedBar: View {
    let percent: Int

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Rectangle().fill(Color.white.opacity(0.35))
                Rectangle().fill(Color.red).frame(width: geometry.size.width * CGFloat(min(max(percent, 0), 100)) / 100)
            }
        }
        .frame(height: 3)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// "Save to Watch later" / "Remove from Watch later", signed in only.
struct WatchLaterMenuItem: View {
    let videoID: String
    private let watchLater = WatchLater.shared

    var body: some View {
        if AccountModel.shared.isSignedIn {
            if watchLater.isSaved(videoID) {
                Button { Task { await watchLater.set(videoID, saved: false) } } label: {
                    Label("Remove from Watch later", systemImage: "clock.badge.xmark")
                }
            } else {
                Button { Task { await watchLater.set(videoID, saved: true) } } label: {
                    Label("Save to Watch later", systemImage: "clock.badge.plus")
                }
            }
        }
    }
}

struct BadgeLabel: View {
    let text: String
    let background: Color
    var systemImage: String?

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(text)
        }
        .font(.caption2.weight(.semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(background, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// A channel result: the round avatar, the name, then "@handle · subscribers".
struct ChannelRow: View {
    let item: FeedItem

    var body: some View {
        HStack(spacing: 14) {
            Thumbnail(url: item.thumbnail, round: true)
                .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title)
                    .font(.headline)
                    .lineLimit(1)
                let details = ([item.channel].compactMap { $0 } + item.details).joined(separator: " · ")
                if !details.isEmpty {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(([item.title, String(localized: "Channel")] + [item.channel].compactMap { $0 } + item.details).joined(separator: ", "))
        .accessibilityAddTraits(.isButton)
    }
}
