import Foundation

/// Picks the pair of files the pipeline plays (US-009, PRD §4.2): H.264 video and AAC-LC audio,
/// chosen by MIME type, size and frame rate, never by hard-coded itags.
public enum FormatSelector {
    /// YouTube serves H.264 up to 1080p; above that only VP9 and AV1 (US-034).
    public static let maxAVCShortSide = 1080

    public struct Selection: Sendable, Equatable {
        public var video: PlayerAnswer.Format?
        public var audio: PlayerAnswer.Format?
    }

    /// - Parameter maxShortSide: the cap, min(screen, user setting, 1080), applied to the video's
    ///   short side so a vertical 1080x1920 video counts as 1080p.
    /// - Parameter prefer60fps: Settings' "Prefer 60 fps"; off, a ≤ 30 fps file of the same size wins
    ///   (60 fps only when it's the only one at that size).
    public static func select(_ answer: PlayerAnswer, maxShortSide: Int = maxAVCShortSide, prefer60fps: Bool = true) -> Selection {
        Selection(video: video(answer.adaptiveFormats, maxShortSide: min(maxShortSide, maxAVCShortSide), prefer60fps: prefer60fps),
                  audio: audio(answer.adaptiveFormats))
    }

    /// The best `video/mp4` avc1 within the cap at ≤ 60 fps: largest, then smoother (or, without
    /// `prefer60fps`, steadier: ≤ 30 fps first), then richer.
    static func video(_ formats: [PlayerAnswer.Format], maxShortSide: Int, prefer60fps: Bool = true) -> PlayerAnswer.Format? {
        formats
            .filter { $0.container == "video/mp4" && $0.codecs.hasPrefix("avc1") && $0.hasDelivery
                && ($0.shortSide ?? .max) <= maxShortSide && ($0.fps ?? 30) <= 60 }
            .max { (left, right) in
                let leftRate = prefer60fps ? (left.fps ?? 0) : -(left.fps ?? 0)
                let rightRate = prefer60fps ? (right.fps ?? 0) : -(right.fps ?? 0)
                return (left.shortSide ?? 0, leftRate, left.bitrate ?? 0) < (right.shortSide ?? 0, rightRate, right.bitrate ?? 0)
            }
    }

    /// The highest-bitrate AAC-LC (`mp4a.40.2`) at 44.1 kHz, the model's rate; else any mp4a. Of the
    /// original track when the video has several (`originalTrack`).
    static func audio(_ formats: [PlayerAnswer.Format]) -> PlayerAnswer.Format? {
        let mp4a = originalTrack(formats.filter { $0.container == "audio/mp4" && $0.codecs.hasPrefix("mp4a") && $0.hasDelivery })
        let byBitrate = { (left: PlayerAnswer.Format, right: PlayerAnswer.Format) in (left.bitrate ?? 0) < (right.bitrate ?? 0) }
        return mp4a.filter { $0.codecs == "mp4a.40.2" && $0.audioSampleRate == 44_100 }.max(by: byBitrate)
            ?? mp4a.max(by: byBitrate)
    }

    /// A video with several audio tracks (YouTube's dubs, AI dubs included) plays its original
    /// track, as Android's `Media3TrackAdapter.applyOriginalAudioDefault` does: otherwise the
    /// highest bitrate picks a dub as readily as the original (same itag, same bitrate). One track,
    /// or no track marked original: all of them.
    public static func originalTrack(_ audio: [PlayerAnswer.Format]) -> [PlayerAnswer.Format] {
        guard Set(audio.map(\.audioTrackID)).count > 1 else { return audio }
        let originals = audio.filter(\.isOriginalAudio)
        return originals.isEmpty ? audio : originals
    }
}

/// Makes a `/player` answer safe to commit as a test fixture (US-009): only the sections the parser
/// reads are kept; the requester's IP address that googlevideo embeds in every URL (`ip=`, and
/// `/ip/<address>/` in manifest paths) is replaced everywhere it appears; and the cache node names
/// (`rrN---sn-…` hosts, the `mn=` list), which point at the requester's ISP, become
/// `sn-scrubbed-<n>`, the same node keeping the same number. Visitor ids live in the dropped
/// `responseContext`.
public enum AnswerScrubber {
    public static let placeholderIP = "0.0.0.0"
    static let opaqueParameters = "gcr|ei|bui|spc|xpc|svpuc|sig|lsig|initcwndbps|mh|met|rms|pcm2cms|n|pot"

    public static func scrub(_ data: Data) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw URLError(.cannotParseResponse)
        }
        root = root.filter { ["playabilityStatus", "videoDetails", "streamingData"].contains($0.key) }
        var text = String(decoding: try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys, .prettyPrinted]),
                          as: UTF8.self)
        for address in Set(addresses(in: text)) where address != placeholderIP {
            text = text.replacingOccurrences(of: address, with: placeholderIP)
            let encoded = address.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? address
            text = text.replacingOccurrences(of: encoded, with: placeholderIP)
        }
        // Country (`gcr`) and opaque per-request tokens: no test reads them, and they may describe the requester.
        // Query form (`&gcr=xx`) and manifest-path form (`/gcr/xx/`, slashes JSON-escaped as `\/`).
        let forms = [(#"([?&]|\\u0026)("# + opaqueParameters + #")=[^&"\\]+"#, "$1$2=scrubbed"),
                     (#"(\\?/)("# + opaqueParameters + #")(\\?/)[^/"\\]+"#, "$1$2$3scrubbed")]
        for (pattern, template) in forms {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        var numbers: [String: Int] = [:]
        for node in nodeNames(in: text) where numbers[node] == nil { numbers[node] = numbers.count + 1 }
        for (node, number) in numbers.sorted(by: { $0.key.count > $1.key.count }) {
            text = text.replacingOccurrences(of: node, with: "sn-scrubbed-\(number)")
        }
        return Data(text.utf8)
    }

    /// googlevideo cache node names (`sn-<cluster>-<node>` at ISPs, `sn-<node>` at Google's edge), in
    /// order of appearance, without placeholders.
    static func nodeNames(in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"sn-[a-z0-9]{4,}(?:-[a-z0-9]+)?"#) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
            .filter { !$0.hasPrefix("sn-scrubbed-") }
    }

    /// Every `ip=` value and `/ip/<value>/` path segment, percent-decoded.
    static func addresses(in text: String) -> [String] {
        let patterns = [#"[?&]ip=([^&"\\]+)"#, #"/ip/([^/"\\]+)"#, #"\\u0026ip=([^&"\\]+)"#]
        var found: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let range = Range(match.range(at: 1), in: text) else { continue }
                let value = String(text[range])
                found.append(value)
                if let decoded = value.removingPercentEncoding, decoded != value { found.append(decoded) }
            }
        }
        return found
    }
}
