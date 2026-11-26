import Foundation

/// A parsed `/player` answer (US-009): the fields Android's `VideoInfo` reads for playback.
/// YouTube sends many numbers as strings (`"contentLength": "3433514"`); the decoder takes both.
public struct PlayerAnswer: Sendable {
    public struct Playability: Sendable, Equatable {
        public var status: String
        public var reason: String?
        /// `errorScreen.playerErrorMessageRenderer.subreason`, as text.
        public var subreason: String?
        public var playableInEmbed: Bool?
        /// YouTube's structured age-gate marker (0 when absent).
        public var desktopLegacyAgeGateReason: Int

        /// Reason and subreason joined with " • ", the text Android's walk classifies
        /// (`VideoInfo.getPlayabilityStatus`, `ServiceHelper.createInfo`).
        public var text: String? {
            let parts = [reason, subreason].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: " \u{2022} ")
        }
    }

    public struct Thumbnail: Sendable, Equatable {
        public var url: String
        public var width: Int?
        public var height: Int?
    }

    public struct Details: Sendable, Equatable {
        public var videoID: String
        public var title: String?
        public var author: String?
        public var channelID: String?
        public var lengthSeconds: Int?
        public var isLive: Bool
        public var isLiveContent: Bool
        public var thumbnails: [Thumbnail]
    }

    public struct ByteRange: Sendable, Equatable {
        public var start: Int64
        public var end: Int64
    }

    public struct Format: Sendable, Equatable {
        public var itag: Int
        public var mimeType: String
        public var bitrate: Int?
        public var averageBitrate: Int?
        public var width: Int?
        public var height: Int?
        public var fps: Int?
        public var qualityLabel: String?
        /// ftyp + moov.
        public var initRange: ByteRange?
        /// sidx.
        public var indexRange: ByteRange?
        public var contentLength: Int64?
        /// `lastModified` (µs); with itag and contentLength it identifies the file across answers (D39 repoint).
        public var lastModified: String?
        public var url: String?
        public var signatureCipher: String?
        public var audioSampleRate: Int?
        public var audioChannels: Int?
        public var approxDurationMs: Int64?
        /// `audioTrack.id` on a video with several audio tracks (`ar.4`, `en-US.10`): the language,
        /// then the kind (4 = original, 2 = descriptive). Nil when the video has one track.
        public var audioTrackID: String? = nil
        public var audioIsDefault = false
        /// One of YouTube's AI dubs.
        public var isAutoDubbed = false

        /// YouTube's untranslated track (MediaServiceCore `YouTubeHelper.getSabrLanguage`): kind 4,
        /// or the default track when the id has no kind; never an auto-dub.
        public var isOriginalAudio: Bool {
            guard let audioTrackID, !isAutoDubbed else { return false }
            let parts = audioTrackID.split(separator: ".")
            return parts.count == 2 ? parts[1] == "4" : audioIsDefault
        }

        /// `video/mp4`, `audio/webm`, …
        public var container: String { String(mimeType.split(separator: ";").first ?? "").trimmingCharacters(in: .whitespaces) }
        /// `avc1.640028`, `mp4a.40.2`, … from `codecs="…"`.
        public var codecs: String {
            guard let range = mimeType.range(of: "codecs=\"") else { return "" }
            return String(mimeType[range.upperBound...].prefix { $0 != "\"" })
        }
        public var isVideo: Bool { container.hasPrefix("video/") }
        public var isAudio: Bool { container.hasPrefix("audio/") }
        /// A URL, or a cipher the solver can turn into one (US-016).
        public var hasDelivery: Bool { url != nil || signatureCipher != nil }
        /// The resolution class: the short side, so a vertical 1080x1920 video is "1080p".
        public var shortSide: Int? {
            guard let width, let height else { return height ?? width }
            return min(width, height)
        }
    }

    public var playability: Playability
    public var details: Details?
    public var adaptiveFormats: [Format]
    public var hlsManifestURL: String?
    public var dashManifestURL: String?
    /// SABR's endpoint; formats without URLs plus this = a SABR-only answer.
    public var serverAbrStreamingURL: String?
    /// `playbackTracking.videostatsPlaybackUrl.baseUrl`: its `ei`, `vm` and `of` go on the history
    /// pings (VideoInfo / MediaItemFormatInfoImpl), bound to the identity that asked.
    public var videostatsPlaybackURL: String?
    /// The client playback nonce its request carried (set by PlayerSources; the history pings send it).
    public var requestCPN: String?

    public init(json data: Data) throws {
        let raw = try JSONDecoder().decode(Raw.self, from: data)
        let status = raw.playabilityStatus
        playability = Playability(status: status?.status ?? "NO_STATUS", reason: status?.reason,
                                  subreason: status?.errorScreen?.playerErrorMessageRenderer?.subreason?.text,
                                  playableInEmbed: status?.playableInEmbed,
                                  desktopLegacyAgeGateReason: status?.desktopLegacyAgeGateReason?.int ?? 0)
        details = raw.videoDetails.map {
            Details(videoID: $0.videoId, title: $0.title, author: $0.author, channelID: $0.channelId,
                    lengthSeconds: $0.lengthSeconds?.int, isLive: $0.isLive ?? false, isLiveContent: $0.isLiveContent ?? false,
                    thumbnails: ($0.thumbnail?.thumbnails ?? []).map { Thumbnail(url: $0.url, width: $0.width, height: $0.height) })
        }
        adaptiveFormats = (raw.streamingData?.adaptiveFormats ?? []).map {
            Format(itag: $0.itag, mimeType: $0.mimeType, bitrate: $0.bitrate, averageBitrate: $0.averageBitrate,
                   width: $0.width, height: $0.height, fps: $0.fps, qualityLabel: $0.qualityLabel,
                   initRange: $0.initRange?.range, indexRange: $0.indexRange?.range,
                   contentLength: $0.contentLength?.int64, lastModified: $0.lastModified?.string,
                   url: $0.url, signatureCipher: $0.signatureCipher ?? $0.cipher,
                   audioSampleRate: $0.audioSampleRate?.int, audioChannels: $0.audioChannels,
                   approxDurationMs: $0.approxDurationMs?.int64,
                   audioTrackID: $0.audioTrack?.id, audioIsDefault: $0.audioTrack?.audioIsDefault ?? false,
                   isAutoDubbed: $0.audioTrack?.isAutoDubbed ?? false)
        }
        hlsManifestURL = raw.streamingData?.hlsManifestUrl
        dashManifestURL = raw.streamingData?.dashManifestUrl
        serverAbrStreamingURL = raw.streamingData?.serverAbrStreamingUrl
        videostatsPlaybackURL = raw.playbackTracking?.videostatsPlaybackUrl?.baseUrl
    }

    public var isLive: Bool { details?.isLive ?? false }
    /// Some adaptive format can be fetched (directly, or after the signature solve).
    public var hasAdaptiveDelivery: Bool { adaptiveFormats.contains(where: \.hasDelivery) }
    /// OK, formats without URLs, a SABR endpoint: only SABR could play it (not ported, PRD §4.4).
    public var isSABROnly: Bool {
        playability.status == "OK" && !hasAdaptiveDelivery && serverAbrStreamingURL != nil
    }

    public var kind: AnswerKind { AnswerKind(self) }
}

// MARK: - Wire format

private struct Raw: Decodable {
    var playabilityStatus: RawPlayability?
    var videoDetails: RawDetails?
    var streamingData: RawStreaming?
    var playbackTracking: RawTracking?
}

private struct RawTracking: Decodable {
    struct URLHolder: Decodable { var baseUrl: String? }
    var videostatsPlaybackUrl: URLHolder?
}

private struct RawPlayability: Decodable {
    var status: String?
    var reason: String?
    var playableInEmbed: Bool?
    var desktopLegacyAgeGateReason: FlexibleNumber?
    var errorScreen: RawErrorScreen?
}

private struct RawErrorScreen: Decodable {
    var playerErrorMessageRenderer: RawErrorMessage?
}

private struct RawErrorMessage: Decodable {
    var subreason: RawText?
}

/// `{"simpleText": …}` or `{"runs": [{"text": …}]}`.
private struct RawText: Decodable {
    var simpleText: String?
    var runs: [Run]?
    struct Run: Decodable { var text: String? }
    var text: String? { simpleText ?? runs?.compactMap(\.text).joined() }
}

private struct RawDetails: Decodable {
    var videoId: String
    var title: String?
    var author: String?
    var channelId: String?
    var lengthSeconds: FlexibleNumber?
    var isLive: Bool?
    var isLiveContent: Bool?
    var thumbnail: RawThumbnails?
}

private struct RawThumbnails: Decodable {
    var thumbnails: [RawThumbnail]?
}

private struct RawThumbnail: Decodable {
    var url: String
    var width: Int?
    var height: Int?
}

private struct RawStreaming: Decodable {
    var adaptiveFormats: [RawFormat]?
    var hlsManifestUrl: String?
    var dashManifestUrl: String?
    var serverAbrStreamingUrl: String?
}

private struct RawFormat: Decodable {
    var itag: Int
    var mimeType: String
    var bitrate: Int?
    var averageBitrate: Int?
    var width: Int?
    var height: Int?
    var fps: Int?
    var qualityLabel: String?
    var initRange: RawRange?
    var indexRange: RawRange?
    var contentLength: FlexibleNumber?
    var lastModified: FlexibleNumber?
    var url: String?
    var signatureCipher: String?
    var cipher: String?
    var audioSampleRate: FlexibleNumber?
    var audioChannels: Int?
    var approxDurationMs: FlexibleNumber?
    var audioTrack: RawAudioTrack?
}

private struct RawAudioTrack: Decodable {
    var id: String?
    var audioIsDefault: Bool?
    var isAutoDubbed: Bool?
}

private struct RawRange: Decodable {
    var start: FlexibleNumber
    var end: FlexibleNumber
    var range: PlayerAnswer.ByteRange? {
        guard let start = start.int64, let end = end.int64 else { return nil }
        return PlayerAnswer.ByteRange(start: start, end: end)
    }
}

/// A JSON number or a string holding one.
private struct FlexibleNumber: Decodable {
    var string: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            string = text
        } else if let integer = try? container.decode(Int64.self) {
            string = String(integer)
        } else {
            string = String(try container.decode(Double.self))
        }
    }

    var int64: Int64? { Int64(string) }
    var int: Int? { Int(string) }
}
