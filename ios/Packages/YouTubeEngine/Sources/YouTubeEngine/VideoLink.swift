import Foundation

/// A video id (and start time) from a pasted link or a bare id (US-014). Ported from SmartTube's
/// `IntentExtractor.extractVideoId` / `extractVideoTimeMs` (common/…/utils/IntentExtractor.java):
/// the `v` query parameter, else the first of `video_ids`, else a `vnd.youtube://<id>` host, else the
/// last path segment (youtu.be/, shorts/, embed/, live/), accepted when it is 11 characters. iOS also
/// takes a bare id, links without a scheme, and requires the id alphabet (Android checks the length only).
public struct VideoLink: Sendable, Equatable {
    public var videoID: String
    /// From `t=` (`90`, `90s`, `1m30s`, `1h2m3s`); nil when absent or malformed.
    public var startSeconds: Double?

    public init(videoID: String, startSeconds: Double? = nil) {
        self.videoID = videoID
        self.startSeconds = startSeconds
    }

    public static func parse(_ text: String) -> VideoLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isVideoID(trimmed) { return VideoLink(videoID: trimmed) }
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return nil }
        let withScheme = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let components = URLComponents(string: withScheme) else { return nil }
        let query = components.queryItems ?? []
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }

        var id = value("v")
        if id == nil, let list = value("video_ids") { id = list.split(separator: ",").first.map(String.init) }
        if id == nil, components.scheme == "vnd.youtube" { id = components.host }
        if id == nil { id = components.path.split(separator: "/").last.map(String.init) }
        guard let id, isVideoID(id) else { return nil }
        return VideoLink(videoID: id, startSeconds: value("t").flatMap(seconds))
    }

    static func isVideoID(_ text: String) -> Bool {
        text.utf8.count == 11 && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    /// Android's `(\d+)([A-Za-z]{0,2})` matches summed: h, m, s or no unit (seconds).
    static func seconds(_ text: String) -> Double? {
        let matches = text.matches(of: /(\d+)([A-Za-z]{0,2})/)
        guard !matches.isEmpty, matches.map({ $0.output.0.count }).reduce(0, +) == text.count else { return nil }
        var total = 0.0
        for match in matches {
            guard let value = Double(match.output.1) else { return nil }
            switch match.output.2.lowercased() {
            case "", "s": total += value
            case "m": total += value * 60
            case "h": total += value * 3_600
            default: return nil
            }
        }
        return total
    }
}
