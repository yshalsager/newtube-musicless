import AVFoundation
import MediaPipeline
import SwiftUI

/// The player at the top of the watch page (US-020; PRD §8): the picture at 16:9, "Preparing
/// voices…" over the frozen frame while holding, and controls a tap shows: ±10 s and play/pause in
/// the middle, the seek bar, full screen, and a menu with Remove music, quality, speed and PiP.
/// Playback controls and the seek bar keep left-to-right in Arabic (time runs that way).
struct PlayerSurface: View {
    let player: PlayerModel
    let thumbnail: URL?
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var scrub: Double?

    var body: some View {
        ZStack {
            Color.black
            if let layer = player.layer {
                VideoLayerView(layer: layer, active: !player.fullScreen)
            } else if let thumbnail {
                Thumbnail(url: thumbnail).opacity(0.5)
            }
            overlay
            if controls { controlsLayer.transition(.opacity) }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture { setControls(!controls) }
        .onChange(of: player.snapshot?.status) { _, status in
            if status == .playing, controls { scheduleHide() }
            if status == .ended { setControls(true) }  // the replay button shows at the end
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var overlay: some View {
        if let error = player.error {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle").font(.title2)
                Text("This video couldn't be played.").font(.subheadline.weight(.semibold))
                Text(error).font(.caption2).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).lineLimit(2)
                if let videoID = player.videoID {
                    Button("Try again") { Task { await player.play(videoID, resume: true) } }.buttonStyle(.borderedProminent)
                }
            }
            .foregroundStyle(.white)
            .padding()
        } else if player.resolving || player.snapshot?.status == .loading || player.isHolding {
            VStack(spacing: 8) {
                ProgressView().tint(.white)
                if player.isHolding { Text(player.waitingText).font(.footnote).foregroundStyle(.white) }
            }
            .padding(12)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private var controlsLayer: some View {
        ZStack {
            Color.black.opacity(0.35).allowsHitTesting(false)
            HStack(spacing: 44) {
                button("gobackward.10", label: String(localized: "Back 10 seconds")) { await player.skip(-10) }
                button(centerIcon, label: centerLabel, size: .largeTitle) { await player.togglePlay() }
                button("goforward.10", label: String(localized: "Forward 10 seconds")) { await player.skip(10) }
            }
            .environment(\.layoutDirection, .leftToRight)
            VStack {
                HStack {
                    Spacer()
                    PlayerMenu(player: player)
                }
                Spacer()
                HStack(spacing: 10) {
                    if let snapshot = player.snapshot { SeekBar(snapshot: snapshot, scrub: $scrub, player: player) }
                    Button { player.fullScreen = true } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right").font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Full screen")
                    .disabled(player.layer == nil)
                }
                .environment(\.layoutDirection, .leftToRight)
            }
            .padding(10)
        }
        .foregroundStyle(.white)
    }

    private var centerIcon: String {
        if player.snapshot?.status == .ended { return "arrow.counterclockwise" }
        return player.snapshot?.wantsToPlay == false ? "play.fill" : "pause.fill"
    }

    private var centerLabel: String {
        if player.snapshot?.status == .ended { return String(localized: "Replay") }
        return player.snapshot?.wantsToPlay == false ? String(localized: "Play") : String(localized: "Pause")
    }

    private func button(_ systemImage: String, label: String, size: Font = .title, action: @escaping () async -> Void) -> some View {
        Button {
            Task { await action() }
            scheduleHide()
        } label: {
            Image(systemName: systemImage).font(size)
        }
        .accessibilityLabel(label)
    }

    private func setControls(_ on: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { controls = on }
        if on { scheduleHide() }
    }

    /// Controls fade 3 s after the last touch while playing.
    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, player.snapshot?.status == .playing, scrub == nil else { return }
            withAnimation(.easeOut(duration: 0.3)) { controls = false }
        }
    }
}

/// The seek bar with the time on each side; dragging moves a preview, release seeks.
struct SeekBar: View {
    let snapshot: PlayerEngine.Snapshot
    @Binding var scrub: Double?
    let player: PlayerModel

    var body: some View {
        let duration = max(snapshot.duration ?? 0, 1)
        HStack(spacing: 8) {
            Text(Self.clock(scrub ?? snapshot.position)).monospacedDigit()
            Slider(value: Binding(get: { scrub ?? snapshot.position }, set: { scrub = $0 }), in: 0...duration) { editing in
                if !editing, let target = scrub {
                    Task {
                        await player.seek(to: target)
                        scrub = nil
                    }
                }
            }
            .tint(.accentColor)
            .accessibilityLabel("Position")
            .accessibilityValue(Self.clock(snapshot.position))
            Text(Self.clock(duration)).monospacedDigit()
        }
        .font(.caption2)
    }

    /// The position in the locale's digits (Arabic-Indic in ar_SA), as the system's players show it.
    static func clock(_ seconds: Double) -> String {
        let duration = Duration.seconds(Int(max(seconds, 0).rounded(.down)))
        return duration.formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }
}

/// The player's menu (Android's gear menu): Remove music, quality, speed, Picture in Picture.
struct PlayerMenu: View {
    let player: PlayerModel

    var body: some View {
        Menu {
            Toggle(isOn: Binding(get: { player.removeMusic }, set: { on in Task { await player.setRemoveMusic(on) } })) {
                Label("Remove music", systemImage: "music.note.slash")
            }
            if !player.qualities.isEmpty {
                Picker(selection: Binding(get: { player.quality?.itag ?? player.qualities.first?.itag ?? 0 },
                                          set: { itag in
                                              guard let option = player.qualities.first(where: { $0.itag == itag }) else { return }
                                              Task { await player.setQuality(option) }
                                          })) {
                    ForEach(player.qualities) { option in Text(option.label).tag(option.itag) }
                } label: {
                    Label("Quality", systemImage: "slider.horizontal.3")
                }
                .pickerStyle(.menu)
            }
            Picker(selection: Binding(get: { player.speed }, set: { value in Task { await player.setSpeed(value) } })) {
                ForEach(PlayerModel.speeds, id: \.self) { value in
                    Text(value == 1 ? String(localized: "Normal") : "\(value.formatted())×").tag(value)
                }
            } label: {
                Label("Speed", systemImage: "gauge.with.dots.needle.33percent")
            }
            .pickerStyle(.menu)
            if player.layer != nil {
                Button { player.startPictureInPicture() } label: { Label("Picture in Picture", systemImage: "pip.enter") }
            }
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.title3)
                .padding(6)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Player settings")
    }
}
