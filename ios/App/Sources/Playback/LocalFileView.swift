import SwiftUI

/// A local file playing with the music removed (US-027): the player, the file's name, and the
/// Remove music switch (also in the player's menu).
struct LocalFileView: View {
    let url: URL
    var voicesOnly = false
    let player: PlayerModel

    var body: some View {
        VStack(spacing: 0) {
            PlayerSurface(player: player, thumbnail: nil)
            List {
                VStack(alignment: .leading, spacing: 6) {
                    Text(url.deletingPathExtension().lastPathComponent)
                        .font(.title3.weight(.semibold))
                    Text("On this iPhone · \(url.pathExtension.uppercased())")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowSeparator(.hidden)
                if voicesOnly {
                    Label("Saved without music", systemImage: "music.note.slash").foregroundStyle(.secondary)
                } else {
                    Toggle(isOn: Binding(get: { player.removeMusic }, set: { on in Task { await player.setRemoveMusic(on) } })) {
                        Label("Remove music", systemImage: "music.note.slash")
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(player.fullScreen ? .hidden : .visible, for: .navigationBar)
        .task { await player.playFile(url, voicesOnly: voicesOnly) }
        .fullScreenCover(isPresented: Binding(get: { player.fullScreen }, set: { player.fullScreen = $0 })) {
            if let layer = player.layer { FullScreenVideo(watch: player, layer: layer) }
        }
        .onChange(of: player.fullScreen) { _, on in FullScreenVideo.rotate(on ? .landscape : .portrait) }
    }
}
