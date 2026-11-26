import AVFoundation
import CoreMedia
import Foundation
import Testing
import VideoToolbox
import os
@testable import MediaPipeline

/// US-011: the demuxer on Big Buck Bunny's AAC (itag 140) and H.264 144p (itag 160) as YouTube serves
/// them (Fixtures/media, CC BY 3.0). Real decodes prove the format descriptions and samples.
@Suite struct FMP4Tests {
    struct Manifest: Decodable {
        struct File: Decodable {
            struct Segment: Decodable { let start: Int64; let end: Int64; let startTime: UInt64; let duration: UInt32 }
            let itag: Int
            let initRange: [Int64]
            let indexRange: [Int64]
            let references: Int
            let timescale: UInt32
            let segments: [Segment]
        }
        let files: [File]
    }

    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/media"))
        return try Data(contentsOf: url)
    }

    static func manifest(_ itag: Int) throws -> Manifest.File {
        try #require(try JSONDecoder().decode(Manifest.self, from: data("manifest.json")).files.first { $0.itag == itag })
    }

    // MARK: Init

    @Test func audioInitDescribesAACLCAt44100Stereo() throws {
        let track = try #require(try FMP4Demuxer.parseInit(Self.data("140-init.mp4")).audio)
        #expect(track.codec == "mp4a")
        #expect(track.timescale == 44_100)
        #expect(track.channels == 2)
        #expect(track.sampleRate == 44_100)
        let config = try #require(track.audioSpecificConfig)
        let fields = try #require(FMP4Demuxer.audioSpecificConfigFields(config))
        #expect(fields.objectType == 2 && fields.sampleRate == 44_100 && fields.channels == 2)
        // YouTube's AAC has no edit list and no gapless tag (DECISIONS D42): nothing to trim here.
        #expect(track.editMediaTime == 0)
        #expect(track.priming == CMTime(value: 0, timescale: 44_100))
        _ = try track.formatDescription()
    }

    @Test func videoInitCarriesSPSAndPPS() throws {
        let track = try #require(try FMP4Demuxer.parseInit(Self.data("160-init.mp4")).video)
        #expect(track.codec == "avc1")
        #expect(track.width == 256 && track.height == 144)
        #expect(track.timescale == 15_360)
        #expect(track.sequenceParameterSets.count == 1 && track.pictureParameterSets.count == 1)
        #expect(track.nalLengthSize == 4)
        let format = try track.formatDescription()
        let dimensions = CMVideoFormatDescriptionGetDimensions(format)
        #expect(dimensions.width == 256 && dimensions.height == 144)
    }

    // MARK: Index

    @Test(arguments: [140, 160])
    func indexReferencesMatchTheRecordedRanges(itag: Int) throws {
        let file = try Self.manifest(itag)
        let index = try FMP4Demuxer.parseIndex(Self.data("\(itag)-index.sidx"), fileOffset: file.indexRange[0])
        #expect(index.references.count == file.references)
        #expect(index.timescale == file.timescale)
        #expect(index.references.first?.bytes.lowerBound == file.indexRange[1] + 1, "segments follow the sidx")
        for (reference, segment) in zip(index.references, file.segments) {
            #expect(reference.bytes == segment.start...segment.end)
            #expect(reference.startTime == segment.startTime)
            #expect(reference.duration == segment.duration)
            #expect(reference.startsWithSAP)
        }
        for (previous, next) in zip(index.references, index.references.dropFirst()) {
            #expect(next.bytes.lowerBound == previous.bytes.upperBound + 1)
            #expect(next.startTime == previous.startTime + UInt64(previous.duration))
        }
    }

    @Test func seekMapsATimeToItsSegment() throws {
        let file = try Self.manifest(140)
        let index = try FMP4Demuxer.parseIndex(Self.data("140-index.sidx"), fileOffset: file.indexRange[0])
        let second = index.seconds(index.references[1].startTime)  // ≈ 9.98 s
        #expect(index.seek(to: 0)?.index == 0)
        #expect(index.seek(to: second - 0.01)?.index == 0)
        #expect(index.seek(to: second)?.index == 1)
        #expect(index.seek(to: 15)?.reference.bytes == index.references[1].bytes)
        #expect(index.seek(to: 1e9)?.index == index.references.count - 1)
        #expect(index.seek(to: -3)?.index == 0)
    }

    // MARK: Fragments

    @Test func audioSegmentsAreContinuousSyncPacketsOf1024() throws {
        let track = try #require(try FMP4Demuxer.parseInit(Self.data("140-init.mp4")).audio)
        let first = try FMP4Demuxer.parseSegment(Self.data("140-seg0.m4s"), track: track)
        let second = try FMP4Demuxer.parseSegment(Self.data("140-seg1.m4s"), track: track)
        #expect(first.count == 430)  // 440320 / 1024
        #expect(first.allSatisfy { $0.isSync && $0.duration == 1024 && !$0.data.isEmpty })
        #expect(first.first?.decodeTime == 0)
        #expect(second.first?.decodeTime == first.last.map { $0.decodeTime + Int64($0.duration) })
    }

    @Test func videoSegmentStartsWithASyncFrame() throws {
        let track = try #require(try FMP4Demuxer.parseInit(Self.data("160-init.mp4")).video)
        let samples = try FMP4Demuxer.parseSegment(Self.data("160-seg0.m4s"), track: track)
        #expect(!samples.isEmpty)
        #expect(samples.first?.isSync == true)
        #expect(samples.dropFirst().contains { !$0.isSync })
        let file = try Self.manifest(160)
        let total = samples.reduce(0) { $0 + Int64($1.duration) }
        #expect(total == Int64(file.segments[0].duration), "the samples cover the sidx reference")
        // AVCC: every sample is length-prefixed NAL units that fill it exactly.
        for sample in samples.prefix(10) {
            var at = 0
            let bytes = [UInt8](sample.data)
            while at + 4 <= bytes.count {
                let length = Int(bytes[at]) << 24 | Int(bytes[at + 1]) << 16 | Int(bytes[at + 2]) << 8 | Int(bytes[at + 3])
                at += 4 + length
            }
            #expect(at == bytes.count)
        }
    }

    // MARK: Decoding through the format descriptions

    @Test func theFirstVideoFrameDecodes() throws {
        let track = try #require(try FMP4Demuxer.parseInit(Self.data("160-init.mp4")).video)
        let format = try track.formatDescription()
        let samples = try FMP4Demuxer.parseSegment(Self.data("160-seg0.m4s"), track: track)
        let buffer = try track.sampleBuffer(try #require(samples.first), format: format)
        #expect(CMSampleBufferGetPresentationTimeStamp(buffer) == CMTime(value: samples[0].presentationTime, timescale: 15_360))
        let notSync = try track.sampleBuffer(try #require(samples.first { !$0.isSync }), format: format)
        let attachments = CMSampleBufferGetSampleAttachmentsArray(notSync, createIfNecessary: false) as? [[CFString: Any]]
        #expect(attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool == true)

        var session: VTDecompressionSession?
        #expect(VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                             imageBufferAttributes: nil, outputCallback: nil, decompressionSessionOut: &session) == noErr)
        let decoder = try #require(session)
        defer { VTDecompressionSessionInvalidate(decoder) }
        let result = OSAllocatedUnfairLock(initialState: (status: OSStatus(-1), width: 0))
        let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: buffer, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
            let width = image.map(CVPixelBufferGetWidth) ?? 0
            result.withLock { $0 = (status, width) }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(decoder)
        let decoded = result.withLock { $0 }
        #expect(status == noErr && decoded.status == noErr)
        #expect(decoded.width == 256)
    }

    @Test func aacPacketsDecodeToStereoPCM() throws {
        let track = try #require(try FMP4Demuxer.parseInit(Self.data("140-init.mp4")).audio)
        let format = try track.formatDescription()
        let samples = Array(try FMP4Demuxer.parseSegment(Self.data("140-seg0.m4s"), track: track).prefix(200))
        let input = AVAudioFormat(cmAudioFormatDescription: format)
        let output = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 2, interleaved: false))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: AVAudioPacketCount(samples.count),
                                                 maximumPacketSize: samples.map(\.data.count).max() ?? 0)
        var offset = 0
        for (index, sample) in samples.enumerated() {
            sample.data.withUnsafeBytes { compressed.data.advanced(by: offset).copyMemory(from: $0.baseAddress!, byteCount: sample.data.count) }
            compressed.packetDescriptions![index] = AudioStreamPacketDescription(mStartOffset: Int64(offset), mVariableFramesInPacket: 0,
                                                                                 mDataByteSize: UInt32(sample.data.count))
            offset += sample.data.count
        }
        compressed.packetCount = AVAudioPacketCount(samples.count)
        compressed.byteLength = UInt32(offset)

        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: AVAudioFrameCount(samples.count * 1024)))
        let given = Given(compressed)
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
            if let buffer = given.once() {
                inputStatus.pointee = .haveData
                return buffer
            }
            inputStatus.pointee = .endOfStream
            return nil
        }
        #expect(error == nil && status != .error)
        let frames = Int(pcm.frameLength)
        // The decoder hands back about one packet per packet given (its own latency aside).
        #expect(frames > (samples.count - 3) * 1024 && frames <= samples.count * 1024, "\(frames) frames")
        var energy: Float = 0
        for channel in 0..<2 { for i in 0..<frames { energy += pcm.floatChannelData![channel][i] * pcm.floatChannelData![channel][i] } }
        #expect(energy > 0, "the opening of Big Buck Bunny isn't silent")
        print("AAC decode: \(samples.count) packets -> \(frames) frames (\(samples.count * 1024 - frames) fewer)")
    }
}

/// Hands the buffer over on the first call only (the converter's input block runs synchronously
/// inside `convert`, so the unchecked Sendable is safe).
private final class Given: @unchecked Sendable {
    private var buffer: AVAudioCompressedBuffer?
    init(_ buffer: AVAudioCompressedBuffer) { self.buffer = buffer }
    func once() -> AVAudioCompressedBuffer? { defer { buffer = nil }; return buffer }
}
