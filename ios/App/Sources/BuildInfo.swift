import Foundation

/// Version and commit of this build. `GitCommit` is written into the built Info.plist by the
/// "Stamp git commit" build phase (project.yml).
enum BuildInfo {
    static let version = info("CFBundleShortVersionString")
    static let build = info("CFBundleVersion")
    static let commit = info("GitCommit")
    static let bundleID = Bundle.main.bundleIdentifier ?? "unknown"

    /// "0.1.0 (1) · 7ed9291"
    static var summary: String { "\(version) (\(build)) · \(commit)" }

    private static func info(_ key: String) -> String {
        Bundle.main.object(forInfoDictionaryKey: key) as? String ?? "unknown"
    }
}
