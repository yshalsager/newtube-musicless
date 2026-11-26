import MusiclessCore
import OSLog
import SwiftUI
import UIKit

/// Settings (US-024; PRD §5, Android's phone Settings screen): music removal and the voice models,
/// playback, language, About with the licences, and a debug section.
struct SettingsView: View {
    @Environment(ModelStore.self) private var models
    @Bindable private var settings = AppSettings.shared
    let player: PlayerModel?

    var body: some View {
        List {
            Section {
                Toggle(isOn: $settings.removeMusic) {
                    Label("Remove music", systemImage: "music.note.slash")
                }
                .onChange(of: settings.removeMusic) { _, on in
                    if on { models.start() }
                    if let player, player.isActive { Task { await player.setRemoveMusic(on) } }
                }
                VoiceModelsRow()
            } header: {
                Text("Music removal")
            } footer: {
                Text("The voice models run on this iPhone; nothing is sent anywhere. They download once.")
            }

            Section("Playback") {
                Picker(selection: $settings.maxQuality) {
                    ForEach(AppSettings.MaxQuality.allCases) { quality in Text(quality.label).tag(quality) }
                } label: {
                    Label("Maximum quality", systemImage: "sparkles.tv")
                }
                Toggle(isOn: $settings.prefer60fps) { Label("Prefer 60 fps", systemImage: "speedometer") }
                Toggle(isOn: $settings.backgroundPlay) { Label("Background play", systemImage: "lock.iphone") }
                Toggle(isOn: $settings.showUpNext) { Label("Show Up next", systemImage: "list.bullet.below.rectangle") }
                Toggle(isOn: $settings.showHome) { Label("Show Home", systemImage: "house") }
            }

            Section {
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                } label: {
                    LabeledContent {
                        Text(Locale.current.localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "") ?? "")
                    } label: {
                        Label("Language", systemImage: "globe")
                    }
                }
                .foregroundStyle(.primary)
            } footer: {
                Text("The app's language is set in iOS Settings, on the app's page.")
            }

            Section("About") {
                LabeledContent("Version", value: "\(BuildInfo.version) (\(BuildInfo.build))")
                ForEach(Licence.all) { licence in
                    NavigationLink(licence.title) { LicenceView(licence: licence) }
                }
            }

            Section("Debug") {
                NavigationLink(value: RootView.Route.probe) { Label("Device probe", systemImage: "cpu") }
                NavigationLink(value: RootView.Route.benchmark(autoStart: nil)) { Label("Separation benchmark", systemImage: "speedometer") }
                NavigationLink(value: RootView.Route.voices(id: nil, at: 0)) { Label("Watch (debug)", systemImage: "play.rectangle") }
                if let player {
                    Toggle(isOn: Binding(get: { player.syntheticWall }, set: { player.syntheticWall = $0 })) {
                        Label("Synthetic wall at 1:00", systemImage: "rectangle.portrait.slash")
                    }
                }
                LogExportRow()
                LabeledContent("Commit", value: BuildInfo.commit).font(.footnote)
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// The voice models: status and size, with Download, Retry or Re-download (US-004's store).
struct VoiceModelsRow: View {
    @Environment(ModelStore.self) private var models
    @State private var confirmRedownload = false

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Voice models")
                    Text(detail).font(.footnote).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "waveform")
            }
            Spacer()
            switch models.status {
            case .notDownloaded: Button("Download") { models.start() }.buttonStyle(.borderless)
            case .failed: Button("Retry") { models.retry() }.buttonStyle(.borderless)
            case .downloading: ProgressView()
            case .ready: Button("Re-download") { confirmRedownload = true }.buttonStyle(.borderless)
            }
        }
        .confirmationDialog("Download the voice models again?", isPresented: $confirmRedownload, titleVisibility: .visible) {
            Button("Re-download") { models.redownload() }
        }
    }

    private var detail: String {
        switch models.status {
        case .ready: ByteCountFormatter.string(fromByteCount: models.bytesOnDisk, countStyle: .file)
        default: models.status.summary
        }
    }
}

/// The licences shipped with the Android app (`assets/musicless/`).
struct Licence: Identifiable {
    let id: String
    let title: String

    static let all = [
        Licence(id: "LICENSE-Musicless.txt", title: "Musicless"),
        Licence(id: "LICENSE-Spleeter.txt", title: "Spleeter"),
        Licence(id: "LICENSE-ONNXRuntime.txt", title: "ONNX Runtime"),
        Licence(id: "ThirdPartyNotices-ONNXRuntime.txt", title: String(localized: "ONNX Runtime third-party notices")),
        Licence(id: "NOTICE.txt", title: "NOTICE"),
    ]

    var text: String {
        guard let url = Bundle.main.url(forResource: id, withExtension: nil) else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

struct LicenceView: View {
    let licence: Licence

    var body: some View {
        // A text view: the third-party notices are 335 KB, too long for one SwiftUI Text.
        PlainTextView(text: licence.text)
            .navigationTitle(licence.title)
            .navigationBarTitleDisplayMode(.inline)
    }
}

struct PlainTextView: UIViewRepresentable {
    let text: String

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.font = .monospacedSystemFont(ofSize: UIFont.preferredFont(forTextStyle: .footnote).pointSize, weight: .regular)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 16, left: 12, bottom: 16, right: 12)
        view.backgroundColor = .clear
        view.text = text
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {}
}

/// Debug: this launch's log lines as a text file to share (OSLogStore, the app's own entries).
struct LogExportRow: View {
    @State private var file: URL?
    @State private var working = false

    var body: some View {
        if let file {
            ShareLink(item: file) { Label("Share the log", systemImage: "square.and.arrow.up") }
        } else {
            Button {
                working = true
                Task {
                    file = await Self.export()
                    working = false
                }
            } label: {
                HStack {
                    Label("Export the log", systemImage: "doc.text")
                    if working { Spacer(); ProgressView() }
                }
            }
            .disabled(working)
        }
    }

    static func export() async -> URL? {
        await Task.detached(priority: .userInitiated) {
            guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return nil }
            let subsystem = Bundle.main.bundleIdentifier ?? ""
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var lines: [String] = ["Musicless \(BuildInfo.summary)"]
            let entries = (try? store.getEntries(matching: NSPredicate(format: "subsystem == %@", subsystem))) ?? AnySequence([])
            for case let entry as OSLogEntryLog in entries {
                lines.append("\(formatter.string(from: entry.date)) [\(entry.category)] \(entry.composedMessage)")
            }
            let url = FileManager.default.temporaryDirectory.appending(path: "musicless-log.txt")
            guard (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
            return url
        }.value
    }
}
