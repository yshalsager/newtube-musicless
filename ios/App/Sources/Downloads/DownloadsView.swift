import SwiftUI

/// You → Downloads (US-028): each download's progress, and the finished files to play (they are
/// also in Files → On My iPhone → the app).
struct DownloadsView: View {
    @Binding var path: [RootView.Route]
    private let store = DownloadStore.shared

    var body: some View {
        List {
            ForEach(store.items) { item in
                Button {
                    if let url = item.fileURL { path.append(.file(url, voicesOnly: item.voicesOnly)) }
                } label: {
                    DownloadRow(item: item)
                }
                .buttonStyle(.plain)
                .swipeActions {
                    Button(role: .destructive) { store.delete(item.id) } label: { Label("Delete", systemImage: "trash") }
                    if item.isActive {
                        Button { store.cancel(item.id) } label: { Label("Cancel", systemImage: "xmark") }
                    } else if case .failed = item.state {
                        Button { store.retry(item.id) } label: { Label("Retry", systemImage: "arrow.clockwise") }.tint(.accentColor)
                    }
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.items.isEmpty {
                ContentUnavailableView {
                    Label("Downloads", systemImage: "arrow.down.circle")
                } description: {
                    Text("Videos you download appear here, and in Files on this iPhone.")
                }
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DownloadRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(width: 112)
                .overlay { Thumbnail(url: item.thumbnail) }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                Text([item.author, item.qualityLabel].joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                status
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var status: some View {
        switch item.state {
        case .queued:
            Text("Waiting to download").font(.caption).foregroundStyle(.secondary)
        case .downloading(let fraction):
            ProgressView(value: fraction) { Text("Downloading").font(.caption) }
        case .removingMusic(let fraction):
            ProgressView(value: fraction) { Text("Removing music").font(.caption) }
        case .saving:
            ProgressView { Text("Saving").font(.caption) }
        case .done:
            Label(item.voicesOnly ? String(localized: "Downloaded without music") : String(localized: "Downloaded"),
                  systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
        }
    }
}
