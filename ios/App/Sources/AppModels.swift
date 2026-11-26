import Foundation
import MusiclessCore

extension ModelStoreConfiguration {
    /// The app's model store: the Info.plist source, Application Support/musicless (excluded from backup).
    static var app: ModelStoreConfiguration {
        let source = Bundle.main.object(forInfoDictionaryKey: "MusiclessModelBaseURL") as? String
        let baseURL = source.flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let directory = URL.applicationSupportDirectory.appending(path: "musicless", directoryHint: .isDirectory)
        return ModelStoreConfiguration(baseURL: baseURL, directory: directory)
    }
}

extension ModelStatus {
    var summary: String {
        switch self {
        case .notDownloaded: "Not downloaded (about 36 MB)"
        case .downloading(let percent): "Downloading… \(percent)%"
        case .ready: "Ready"
        case .failed(let message): message
        }
    }

    var logValue: String {
        switch self {
        case .notDownloaded: "notDownloaded"
        case .downloading(let percent): "downloading percent=\(percent)"
        case .ready: "ready"
        case .failed(let message): "failed message=\(message)"
        }
    }
}
