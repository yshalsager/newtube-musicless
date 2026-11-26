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

/// Hosts the engine's display layer (the app keeps the layer; the engine feeds its renderer).
struct VideoLayerView: UIViewRepresentable {
    let layer: AVSampleBufferDisplayLayer
    /// Whether this view should hold the layer: the inline view and the full-screen one share it, and
    /// the change of this flag is what makes SwiftUI call `updateUIView` so the layer moves back.
    var active = true

    func makeUIView(context: Context) -> HostView {
        let view = HostView()
        view.backgroundColor = .black
        if active { view.host(layer) }
        return view
    }

    func updateUIView(_ view: HostView, context: Context) {
        if active { view.host(layer) }
    }

    final class HostView: UIView {
        private var hosted: CALayer?

        func host(_ layer: CALayer) {
            // Also when the layer was moved away (the full-screen view hosts the same layer).
            guard hosted !== layer || layer.superlayer !== self.layer else { return }
            if hosted !== layer, hosted?.superlayer === self.layer { hosted?.removeFromSuperlayer() }
            self.layer.addSublayer(layer)
            hosted = layer
            setNeedsLayout()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hosted?.frame = bounds
            CATransaction.commit()
        }
    }
}

/// Full-screen landscape (US-018): the same display layer, rotated to landscape; a tap shows the
/// controls. Closing it puts the layer back in the screen.
struct FullScreenVideo: View {
    let watch: PlayerModel
    let layer: AVSampleBufferDisplayLayer
    @Environment(\.dismiss) private var dismiss
    @State private var controls = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VideoLayerView(layer: layer, active: watch.fullScreen).ignoresSafeArea()
            if controls {
                VStack {
                    HStack {
                        Button { dismiss() } label: { Image(systemName: "xmark").font(.title2) }
                            .accessibilityLabel("Close full screen")
                        Spacer()
                        Text(watch.title).lineLimit(1).font(.headline)
                        Spacer()
                    }
                    Spacer()
                    HStack(spacing: 40) {
                        Button { Task { await watch.skip(-10) } } label: { Image(systemName: "gobackward.10") }
                        Button { Task { await watch.togglePlay() } } label: {
                            Image(systemName: watch.snapshot?.wantsToPlay == false ? "play.fill" : "pause.fill")
                        }
                        Button { Task { await watch.skip(10) } } label: { Image(systemName: "goforward.10") }
                    }
                    .font(.largeTitle)
                    .environment(\.layoutDirection, .leftToRight)
                    Spacer()
                }
                .padding()
                .foregroundStyle(.white)
                .background(.black.opacity(0.35))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { controls.toggle() }
        .statusBarHidden()
    }

    /// The orientation lock changes, and telling the controllers so rotates the scene: the current
    /// orientation is no longer allowed. (An explicit `requestGeometryUpdate` on top of it raced the
    /// controllers' update and was refused, though the rotation happened.)
    static func rotate(_ orientations: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return }
        AppDelegate.orientations = orientations
        var controller = scene.windows.first { $0.isKeyWindow }?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
    }
}
