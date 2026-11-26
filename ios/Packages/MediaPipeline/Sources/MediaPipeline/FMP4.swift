import Foundation

/// YouTube's adaptive files are fragmented MP4 (PRD §4.2): `initRange` holds ftyp + moov,
/// `indexRange` a sidx, and each sidx reference one moof + mdat. This parses the narrow, regular
/// subset they use (US-011). Everything is big-endian.
public enum FMP4Error: Error, Sendable, Equatable {
    case truncated(String)
    case missing(String)
    case unsupported(String)
}

/// A track from the init segment.
public struct FMP4Track: Sendable, Equatable {
    public enum Kind: String, Sendable { case video, audio, other }

    public var id: UInt32
    public var kind: Kind
    /// Media timescale (`mdhd`): sample times count in 1/timescale seconds.
    public var timescale: UInt32
    public var duration: UInt64
    /// Sample entry type: `avc1`, `avc3`, `mp4a`, …
    public var codec: String
    // Video
    public var width: UInt16 = 0
    public var height: UInt16 = 0
    public var sequenceParameterSets: [Data] = []
    public var pictureParameterSets: [Data] = []
    /// Bytes of each NAL unit's length prefix (avcC lengthSizeMinusOne + 1).
    public var nalLengthSize: Int = 4
    // Audio
    public var channels: UInt16 = 0
    public var sampleRate: Double = 0
    /// The esds payload (an MPEG-4 ES_Descriptor), Core Audio's AAC magic cookie.
    public var elementaryStreamDescriptor: Data?
    /// DecoderSpecificInfo inside it.
    public var audioSpecificConfig: Data?
    /// `elst`'s first entry media time, in the media timescale: AAC encoder priming to trim (§4.2).
    public var editMediaTime: Int64 = 0
    // trex defaults
    public var defaultSampleDuration: UInt32 = 0
    public var defaultSampleSize: UInt32 = 0
    public var defaultSampleFlags: UInt32 = 0
}

public struct FMP4Init: Sendable, Equatable {
    public var tracks: [FMP4Track]
    public var video: FMP4Track? { tracks.first { $0.kind == .video } }
    public var audio: FMP4Track? { tracks.first { $0.kind == .audio } }
}

/// The sidx: where each segment sits in the file and when it starts.
public struct FMP4SegmentIndex: Sendable, Equatable {
    public struct Reference: Sendable, Equatable {
        /// Absolute byte range in the file (inclusive).
        public var bytes: ClosedRange<Int64>
        /// Start in the sidx timescale.
        public var startTime: UInt64
        public var duration: UInt32
        public var startsWithSAP: Bool
    }

    public var timescale: UInt32
    public var earliestPresentationTime: UInt64
    public var references: [Reference]

    public func seconds(_ time: UInt64) -> Double { Double(time) / Double(timescale) }

    /// The segment holding `seconds` (the first for earlier times, the last for later ones). A seek
    /// fetches that segment and starts at its first sync sample at or before the target (US-013).
    public func seek(to seconds: Double) -> (index: Int, reference: Reference)? {
        guard !references.isEmpty else { return nil }
        let target = UInt64(max(0, seconds) * Double(timescale))
        let index = references.lastIndex { $0.startTime <= target } ?? 0
        return (index, references[index])
    }
}

/// One sample of a fragment.
public struct FMP4Sample: Sendable, Equatable {
    /// Decode time (DTS) in the track timescale.
    public var decodeTime: Int64
    /// PTS = DTS + offset.
    public var compositionOffset: Int32
    public var duration: UInt32
    public var isSync: Bool
    public var data: Data
    public var presentationTime: Int64 { decodeTime + Int64(compositionOffset) }
}

public enum FMP4Demuxer {
    // MARK: Init segment

    public static func parseInit(_ data: Data) throws -> FMP4Init {
        let reader = BoxReader(data)
        guard let moov = try reader.boxes().first(where: { $0.type == "moov" }) else { throw FMP4Error.missing("moov") }
        var tracks: [FMP4Track] = []
        var trex: [UInt32: (UInt32, UInt32, UInt32)] = [:]
        for box in try BoxReader(moov.payload).boxes() {
            switch box.type {
            case "trak": tracks.append(try parseTrack(box.payload))
            case "mvex":
                for child in try BoxReader(box.payload).boxes() where child.type == "trex" {
                    var r = ByteReader(child.payload)
                    _ = try r.fullBoxHeader()
                    let id = try r.u32()
                    _ = try r.u32()  // default sample description index
                    trex[id] = (try r.u32(), try r.u32(), try r.u32())
                }
            default: break
            }
        }
        for index in tracks.indices {
            if let defaults = trex[tracks[index].id] {
                (tracks[index].defaultSampleDuration, tracks[index].defaultSampleSize, tracks[index].defaultSampleFlags) = defaults
            }
        }
        return FMP4Init(tracks: tracks)
    }

    static func parseTrack(_ data: Data) throws -> FMP4Track {
        var track = FMP4Track(id: 0, kind: .other, timescale: 0, duration: 0, codec: "")
        for box in try BoxReader(data).boxes() {
            switch box.type {
            case "tkhd":
                var r = ByteReader(box.payload)
                let (version, _) = try r.fullBoxHeader()
                try r.skip(version == 1 ? 16 : 8)  // creation + modification time
                track.id = try r.u32()
            case "edts":
                for child in try BoxReader(box.payload).boxes() where child.type == "elst" {
                    var r = ByteReader(child.payload)
                    let (version, _) = try r.fullBoxHeader()
                    if try r.u32() > 0 {
                        _ = version == 1 ? try r.u64() : UInt64(try r.u32())  // segment duration
                        track.editMediaTime = version == 1 ? Int64(bitPattern: try r.u64()) : Int64(Int32(bitPattern: try r.u32()))
                    }
                }
            case "mdia":
                try parseMedia(box.payload, into: &track)
            default: break
            }
        }
        guard track.timescale > 0 else { throw FMP4Error.missing("mdhd") }
        return track
    }

    static func parseMedia(_ data: Data, into track: inout FMP4Track) throws {
        for box in try BoxReader(data).boxes() {
            switch box.type {
            case "mdhd":
                var r = ByteReader(box.payload)
                let (version, _) = try r.fullBoxHeader()
                try r.skip(version == 1 ? 16 : 8)
                track.timescale = try r.u32()
                track.duration = version == 1 ? try r.u64() : UInt64(try r.u32())
            case "hdlr":
                var r = ByteReader(box.payload)
                _ = try r.fullBoxHeader()
                try r.skip(4)  // pre_defined
                switch try r.fourCC() {
                case "vide": track.kind = .video
                case "soun": track.kind = .audio
                default: track.kind = .other
                }
            case "minf":
                for child in try BoxReader(box.payload).boxes() where child.type == "stbl" {
                    for table in try BoxReader(child.payload).boxes() where table.type == "stsd" {
                        try parseSampleDescription(table.payload, into: &track)
                    }
                }
            default: break
            }
        }
    }

    static func parseSampleDescription(_ data: Data, into track: inout FMP4Track) throws {
        var r = ByteReader(data)
        _ = try r.fullBoxHeader()
        guard try r.u32() > 0 else { throw FMP4Error.missing("sample entry") }
        let entries = BoxReader(r.remaining)
        guard let entry = try entries.boxes().first else { throw FMP4Error.missing("sample entry") }
        track.codec = entry.type
        var e = ByteReader(entry.payload)
        try e.skip(8)  // reserved(6) + data_reference_index(2)
        switch entry.type {
        case "avc1", "avc3":
            try e.skip(16)  // pre_defined, reserved, pre_defined[3]
            track.width = try e.u16()
            track.height = try e.u16()
            try e.skip(50)  // resolutions, reserved, frame_count, compressorname(32), depth, pre_defined
            for child in try BoxReader(e.remaining).boxes() where child.type == "avcC" {
                try parseAVCC(child.payload, into: &track)
            }
            guard !track.sequenceParameterSets.isEmpty, !track.pictureParameterSets.isEmpty else { throw FMP4Error.missing("avcC") }
        case "mp4a":
            try e.skip(8)  // reserved
            track.channels = try e.u16()
            try e.skip(6)  // sample size, pre_defined, reserved
            track.sampleRate = Double(try e.u32() >> 16)  // 16.16 fixed point
            for child in try BoxReader(e.remaining).boxes() where child.type == "esds" {
                var d = ByteReader(child.payload)
                _ = try d.fullBoxHeader()
                track.elementaryStreamDescriptor = d.remaining
                track.audioSpecificConfig = try decoderSpecificInfo(d.remaining)
            }
            guard track.audioSpecificConfig != nil else { throw FMP4Error.missing("esds") }
        default:
            throw FMP4Error.unsupported("sample entry \(entry.type)")
        }
    }

    static func parseAVCC(_ data: Data, into track: inout FMP4Track) throws {
        var r = ByteReader(data)
        try r.skip(4)  // version, profile, compatibility, level
        track.nalLengthSize = Int(try r.u8() & 0x03) + 1
        let spsCount = Int(try r.u8() & 0x1F)
        for _ in 0..<spsCount { track.sequenceParameterSets.append(try r.bytes(Int(try r.u16()))) }
        let ppsCount = Int(try r.u8())
        for _ in 0..<ppsCount { track.pictureParameterSets.append(try r.bytes(Int(try r.u16()))) }
    }

    /// The DecoderSpecificInfo (tag 5) inside an ES_Descriptor (tag 3) → DecoderConfigDescriptor (tag 4).
    static func decoderSpecificInfo(_ descriptor: Data) throws -> Data? {
        var r = ByteReader(descriptor)
        while r.hasMore {
            let tag = try r.u8()
            let length = try r.descriptorLength()
            switch tag {
            case 3:  // ES_Descriptor: ES_ID(2), flags(1) [+ optional fields]
                _ = try r.u16()
                let flags = try r.u8()
                if flags & 0x80 != 0 { try r.skip(2) }                 // dependsOn_ES_ID
                if flags & 0x40 != 0 { try r.skip(Int(try r.u8())) }   // URL
                if flags & 0x20 != 0 { try r.skip(2) }                 // OCR_ES_Id
            case 4:  // DecoderConfigDescriptor: objectType(1) streamType(1) bufferSize(3) maxBitrate(4) avgBitrate(4)
                try r.skip(13)
            case 5:
                return try r.bytes(length)
            default:
                try r.skip(length)
            }
        }
        return nil
    }

    /// AudioSpecificConfig: object type, sample rate, channels (ISO 14496-3 §1.6.2.1).
    public static func audioSpecificConfigFields(_ config: Data) -> (objectType: Int, sampleRate: Int, channels: Int)? {
        let bytes = [UInt8](config)
        guard bytes.count >= 2 else { return nil }
        let rates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]
        let objectType = Int(bytes[0] >> 3)
        let rateIndex = Int((bytes[0] & 0x07) << 1 | bytes[1] >> 7)
        let channels = Int((bytes[1] >> 3) & 0x0F)
        guard rateIndex < rates.count else { return nil }
        return (objectType, rates[rateIndex], channels)
    }

    // MARK: Index

    /// `data` is the indexRange's bytes, which start at file offset `fileOffset`.
    public static func parseIndex(_ data: Data, fileOffset: Int64) throws -> FMP4SegmentIndex {
        let reader = BoxReader(data)
        guard let sidx = try reader.boxes().first(where: { $0.type == "sidx" }) else { throw FMP4Error.missing("sidx") }
        var r = ByteReader(sidx.payload)
        let (version, _) = try r.fullBoxHeader()
        _ = try r.u32()  // reference_ID
        let timescale = try r.u32()
        let earliest = version == 0 ? UInt64(try r.u32()) : try r.u64()
        let firstOffset = version == 0 ? UInt64(try r.u32()) : try r.u64()
        try r.skip(2)
        let count = Int(try r.u16())
        // Offsets count from the first byte after the sidx box.
        var position = fileOffset + Int64(sidx.offset + sidx.size) + Int64(firstOffset)
        var time = earliest
        var references: [FMP4SegmentIndex.Reference] = []
        for _ in 0..<count {
            let typeAndSize = try r.u32()
            let duration = try r.u32()
            let sap = try r.u32()
            guard typeAndSize & 0x8000_0000 == 0 else { throw FMP4Error.unsupported("hierarchical sidx") }
            let size = Int64(typeAndSize & 0x7FFF_FFFF)
            references.append(.init(bytes: position...(position + size - 1), startTime: time, duration: duration,
                                    startsWithSAP: sap & 0x8000_0000 != 0))
            position += size
            time += UInt64(duration)
        }
        return FMP4SegmentIndex(timescale: timescale, earliestPresentationTime: earliest, references: references)
    }

    // MARK: Fragments

    /// The samples of `track` in a segment (moof + mdat, as one sidx reference's bytes).
    public static func parseSegment(_ data: Data, track: FMP4Track) throws -> [FMP4Sample] {
        var samples: [FMP4Sample] = []
        let reader = BoxReader(data)
        for moof in try reader.boxes() where moof.type == "moof" {
            for traf in try BoxReader(moof.payload).boxes() where traf.type == "traf" {
                samples += try parseTrackFragment(traf.payload, moofOffset: moof.offset, segment: data, track: track)
            }
        }
        return samples
    }

    static func parseTrackFragment(_ data: Data, moofOffset: Int, segment: Data, track: FMP4Track) throws -> [FMP4Sample] {
        var baseOffset = Int64(moofOffset)  // default-base-is-moof, and YouTube's files
        var duration = track.defaultSampleDuration, size = track.defaultSampleSize, flags = track.defaultSampleFlags
        var decodeTime: Int64 = 0
        var matches = true
        var samples: [FMP4Sample] = []
        for box in try BoxReader(data).boxes() {
            var r = ByteReader(box.payload)
            switch box.type {
            case "tfhd":
                let (_, f) = try r.fullBoxHeader()
                matches = try r.u32() == track.id
                if f & 0x01 != 0 { baseOffset = Int64(bitPattern: try r.u64()) }
                if f & 0x02 != 0 { _ = try r.u32() }  // sample description index
                if f & 0x08 != 0 { duration = try r.u32() }
                if f & 0x10 != 0 { size = try r.u32() }
                if f & 0x20 != 0 { flags = try r.u32() }
            case "tfdt":
                let (version, _) = try r.fullBoxHeader()
                decodeTime = version == 1 ? Int64(bitPattern: try r.u64()) : Int64(try r.u32())
            case "trun" where matches:
                let (version, f) = try r.fullBoxHeader()
                let count = Int(try r.u32())
                var dataOffset = baseOffset
                if f & 0x01 != 0 { dataOffset += Int64(Int32(bitPattern: try r.u32())) }
                let firstFlags = f & 0x04 != 0 ? try r.u32() : nil
                for index in 0..<count {
                    let sampleDuration = f & 0x100 != 0 ? try r.u32() : duration
                    let sampleSize = f & 0x200 != 0 ? try r.u32() : size
                    var sampleFlags = f & 0x400 != 0 ? try r.u32() : flags
                    if index == 0, let firstFlags { sampleFlags = firstFlags }
                    var offset: Int32 = 0
                    if f & 0x800 != 0 {
                        let raw = try r.u32()
                        offset = version == 0 ? Int32(clamping: raw) : Int32(bitPattern: raw)
                    }
                    let start = Int(dataOffset), end = start + Int(sampleSize)
                    guard start >= 0, end <= segment.count else { throw FMP4Error.truncated("sample data") }
                    let base = segment.startIndex
                    samples.append(FMP4Sample(decodeTime: decodeTime, compositionOffset: offset, duration: sampleDuration,
                                              isSync: sampleFlags & 0x0001_0000 == 0,  // sample_is_non_sync_sample
                                              data: segment.subdata(in: (base + start)..<(base + end))))
                    decodeTime += Int64(sampleDuration)
                    dataOffset += Int64(sampleSize)
                }
            default:
                break
            }
        }
        return samples
    }
}

// MARK: - Readers

struct Box {
    let type: String
    /// Offset of the box header in the reader's data.
    let offset: Int
    /// Header + payload.
    let size: Int
    let payload: Data
}

struct BoxReader {
    private let start: ByteReader
    init(_ data: Data) { start = ByteReader(data) }

    /// Every top-level box in the data.
    func boxes() throws -> [Box] {
        var reader = start
        var result: [Box] = []
        while reader.hasMore {
            let start = reader.position
            var size = UInt64(try reader.u32())
            let type = try reader.fourCC()
            var header = 8
            if size == 1 {
                size = try reader.u64()
                header = 16
            } else if size == 0 {
                size = UInt64(reader.count - start)
            }
            guard size >= UInt64(header), start + Int(size) <= reader.count else { throw FMP4Error.truncated(type) }
            let payload = try reader.bytes(Int(size) - header)
            result.append(Box(type: type, offset: start, size: Int(size), payload: payload))
        }
        return result
    }
}

struct ByteReader {
    private let data: Data
    private(set) var position = 0
    init(_ data: Data) { self.data = data }

    var count: Int { data.count }
    var hasMore: Bool { position < data.count }
    var remaining: Data { bytesFrom(position, count - position) }

    private func bytesFrom(_ start: Int, _ length: Int) -> Data {
        let base = data.startIndex
        return data.subdata(in: (base + start)..<(base + start + length))
    }

    mutating func bytes(_ length: Int) throws -> Data {
        guard length >= 0, position + length <= data.count else { throw FMP4Error.truncated("\(length) bytes at \(position)") }
        defer { position += length }
        return bytesFrom(position, length)
    }

    mutating func skip(_ length: Int) throws { _ = try bytes(length) }

    mutating func u8() throws -> UInt8 {
        guard position < data.count else { throw FMP4Error.truncated("u8 at \(position)") }
        defer { position += 1 }
        return data[data.startIndex + position]
    }

    mutating func u16() throws -> UInt16 { UInt16(try u8()) << 8 | UInt16(try u8()) }
    mutating func u32() throws -> UInt32 { UInt32(try u16()) << 16 | UInt32(try u16()) }
    mutating func u64() throws -> UInt64 { UInt64(try u32()) << 32 | UInt64(try u32()) }

    mutating func fourCC() throws -> String { String(decoding: try bytes(4), as: UTF8.self) }

    /// version(8) + flags(24).
    mutating func fullBoxHeader() throws -> (UInt8, UInt32) {
        let value = try u32()
        return (UInt8(value >> 24), value & 0x00FF_FFFF)
    }

    /// MPEG-4 descriptor length: up to four bytes, 7 bits each, high bit = more.
    mutating func descriptorLength() throws -> Int {
        var length = 0
        for _ in 0..<4 {
            let byte = try u8()
            length = length << 7 | Int(byte & 0x7F)
            if byte & 0x80 == 0 { break }
        }
        return length
    }
}
