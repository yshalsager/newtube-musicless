import AVFoundation
import AVKit
import MediaPlayer
import Foundation
import MediaPipeline
import MusiclessCore
import Observation
import SwiftUI
import UIKit
import YouTubeEngine

/// The player lives in `watch`, which RootView owns and stops when this screen's route is popped,
/// not on `onDisappear`, so nothing the system does to the view (a lock, a sheet) can stop it.
struct WatchDebugView: View {
    let watch: PlayerModel
    var autoPlay: (id: String, at: Double)?
    var seekCheck = false
    var backgroundTest = false
    var qualityCheck = false
    var wallCheck = false
    var systemCheck = false
    @State private var link = ""
    /// The seek bar's value while it is being dragged; nil otherwise.
    @State private var scrub: Double?

    var body: some View {
        List {
            Section {
                if let layer = watch.layer {
                    VideoLayerView(layer: layer, active: !watch.fullScreen)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { overlay }
                        .listRowInsets(EdgeInsets())
                } else if watch.isActive {
                    Color.black.aspectRatio(16 / 9, contentMode: .fit)
                        .overlay { overlay }
                        .listRowInsets(EdgeInsets())
                }
                linkRow
            }
            if watch.isActive || watch.error != nil || watch.resolving {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(watch.title).font(.headline)
                        if !watch.detail.isEmpty {
                            Text(watch.detail).font(.footnote).foregroundStyle(.secondary)
                        }
                        Text(watch.statusText).font(.callout)
                    }
                    .textSelection(.enabled)
                    if let snapshot = watch.snapshot { seekBar(snapshot) }
                    controls
                    Toggle("Remove music", isOn: Binding(get: { watch.removeMusic },
                                                         set: { on in Task { await watch.setRemoveMusic(on) } }))
                    Picker("Speed", selection: Binding(get: { watch.speed }, set: { value in Task { await watch.setSpeed(value) } })) {
                        ForEach(PlayerModel.speeds, id: \.self) { value in Text(value == 1 ? "Normal" : "\(value.formatted())×").tag(value) }
                    }
                    if watch.layer != nil {
                        HStack {
                            Button("Full screen") { watch.fullScreen = true }
                            Spacer()
                            Button("Picture in Picture") { watch.startPictureInPicture() }
                        }
                        .buttonStyle(.borderless)
                    }
                    if !watch.qualities.isEmpty {
                        // Selected by itag: SwiftUI may read the binding once more after `stop()` empties the list.
                        Picker("Quality", selection: Binding(get: { watch.quality?.itag ?? watch.qualities.first?.itag ?? 0 },
                                                             set: { itag in
                                                                 guard let option = watch.qualities.first(where: { $0.itag == itag }) else { return }
                                                                 Task { await watch.setQuality(option) }
                                                             })) {
                            ForEach(watch.qualities) { option in Text(option.label).tag(option.itag) }
                        }
                    }
                }
            }
            Section {
                ForEach(PlayerModel.presets) { preset in
                    Button {
                        Task { await watch.play(preset.id) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(preset.title)
                            Text(preset.expect).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Videos")
            } footer: {
                Text("Plays the video with the music removed. Switch Remove music off to hear the original. "
                     + "Lock the screen: the voices keep playing.")
            }
            Section("Debug") {
                ModelStatusRow()
                Toggle("Audio only", isOn: Binding(get: { watch.audioOnly }, set: { watch.audioOnly = $0 }))
                Toggle("Synthetic wall at 1:00", isOn: Binding(get: { watch.syntheticWall }, set: { watch.syntheticWall = $0 }))
            }
        }
        .navigationTitle("Watch (debug)")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: Binding(get: { watch.fullScreen }, set: { watch.fullScreen = $0 })) {
            if let layer = watch.layer { FullScreenVideo(watch: watch, layer: layer) }
        }
        .onChange(of: watch.fullScreen) { _, on in FullScreenVideo.rotate(on ? .landscape : .portrait) }
        .task {
            if wallCheck {
                await watch.runWallCheck()
                return
            }
            guard let autoPlay else { return }
            await watch.play(autoPlay.id, at: autoPlay.at)
            if seekCheck {
                while watch.snapshot?.status != .playing { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .seconds(3))
                await watch.runSeekCheck()
            }
            if backgroundTest { await watch.runBackgroundTest() }
            if qualityCheck { await watch.runQualityCheck() }
            if systemCheck { await watch.runSystemCheck() }
        }
    }

    @ViewBuilder private var overlay: some View {
        if watch.isHolding {
            VStack(spacing: 8) {
                ProgressView()
                Text(watch.waitingText).font(.callout)
            }
            .padding(12)
            .background(.black.opacity(0.65), in: .rect(cornerRadius: 10))
            .foregroundStyle(.white)
        }
    }

    private var linkRow: some View {
        HStack {
            TextField("YouTube link or video id", text: $link)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .submitLabel(.go)
                .onSubmit(open)
            // PasteButton reads the clipboard without the paste prompt.
            PasteButton(payloadType: String.self) { strings in
                guard let text = strings.first else { return }
                Task { @MainActor in
                    link = text
                    open()
                }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
            Button("Play", action: open)
                .disabled(VideoLink.parse(link) == nil)
        }
    }

    private func open() {
        guard let parsed = VideoLink.parse(link) else { return }
        Task { await watch.play(parsed) }
    }

    private func seekBar(_ snapshot: PlayerEngine.Snapshot) -> some View {
        let duration = max(snapshot.duration ?? 0, 1)
        return VStack(spacing: 2) {
            Slider(value: Binding(get: { scrub ?? min(snapshot.position, duration) }, set: { scrub = $0 }),
                   in: 0...duration) { editing in
                if !editing, let target = scrub {
                    Task {
                        await watch.seek(to: target)
                        scrub = nil
                    }
                }
            }
            HStack {
                Text(Self.clock(scrub ?? snapshot.position))
                Spacer()
                Text(Self.buffers(snapshot)).foregroundStyle(.tertiary)
                Spacer()
                Text(Self.clock(snapshot.duration ?? 0))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        // Timelines and playback controls show the tape's direction, so they aren't mirrored in
        // right-to-left languages (Apple HIG, "Right to left").
        .environment(\.layoutDirection, .leftToRight)
    }

    private var controls: some View {
        HStack(spacing: 28) {
            Button { Task { await watch.skip(-10) } } label: { Image(systemName: "gobackward.10") }
                .accessibilityLabel("Back 10 seconds")
            Button { Task { await watch.togglePlay() } } label: {
                Image(systemName: watch.snapshot?.wantsToPlay == false ? "play.fill" : "pause.fill")
            }
            .accessibilityLabel(watch.snapshot?.wantsToPlay == false ? "Play" : "Pause")
            Button { Task { await watch.skip(10) } } label: { Image(systemName: "goforward.10") }
                .accessibilityLabel("Forward 10 seconds")
            Spacer()
            Button("Stop", role: .destructive) { Task { await watch.stop(reason: "stop button") } }
        }
        .buttonStyle(.borderless)
        .font(.title3)
        .environment(\.layoutDirection, .leftToRight)
    }

    static func buffers(_ snapshot: PlayerEngine.Snapshot) -> String {
        var line = "voices \(String(format: "%.1f", max(0, snapshot.aheadSeconds))) s"
        if let video = snapshot.videoAheadSeconds {
            line += snapshot.videoActive ? " · picture \(String(format: "%.1f", max(0, video))) s" : " · picture off"
        }
        return line
    }

    static func clock(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        return total >= 3_600 ? String(format: "%d:%02d:%02d", total / 3_600, total / 60 % 60, total % 60)
            : String(format: "%d:%02d", total / 60, total % 60)
    }
}
