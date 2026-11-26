import AVFoundation
import CoreMedia
import Foundation

public struct AACDecoderError: Error, Sendable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

/// AAC packets from the demuxer to interleaved Float32 PCM at the track's own rate, through
/// `AVAudioConverter` (US-012, PRD §4.2). Mono stays mono and other rates stay as they are: the
/// separation stage converts to 44.1 kHz stereo itself, so nothing is resampled twice. More than two
/// channels are mixed down to stereo.
///
/// Streaming: each `decode` hands over one batch and asks for what is ready ("no data now", not end
/// of stream), so the decoder keeps its state across segments; `finish()` drains it at the end.
/// One feed owns a decoder; it isn't shared across tasks.
public final class AACDecoder {
    public let sampleRate: Double
    public let channels: Int
    private let input: AVAudioFormat
    private let output: AVAudioFormat
    private let converter: AVAudioConverter

    public init(track: FMP4Track) throws {
        guard track.kind == .audio else { throw AACDecoderError("not an audio track") }
        let description = try track.formatDescription()
        input = AVAudioFormat(cmAudioFormatDescription: description)
        sampleRate = input.sampleRate
        channels = min(Int(input.channelCount), 2)
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels), interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw AACDecoderError("no decoder for \(input)")
        }
        self.output = output
        self.converter = converter
    }

    /// Decodes a batch of packets; returns the PCM the decoder has ready (interleaved).
    public func decode(_ samples: [FMP4Sample]) throws -> [Float] {
        guard !samples.isEmpty else { return [] }
        let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: AVAudioPacketCount(samples.count),
                                                 maximumPacketSize: samples.map(\.data.count).max() ?? 0)
        var offset = 0
        for (index, sample) in samples.enumerated() {
            sample.data.withUnsafeBytes { raw in
                compressed.data.advanced(by: offset).copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }
            compressed.packetDescriptions![index] = AudioStreamPacketDescription(
                mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(sample.data.count))
            offset += sample.data.count
        }
        compressed.packetCount = AVAudioPacketCount(samples.count)
        compressed.byteLength = UInt32(offset)
        return try run(Feed(compressed, endOfStream: false), frames: samples.count * 1024)
    }

    /// End of stream: whatever the decoder still holds. The decoder is reset afterwards.
    public func finish() throws -> [Float] {
        defer { converter.reset() }
        return try run(Feed(nil, endOfStream: true), frames: 4096)
    }

    private func run(_ feed: Feed, frames: Int) throws -> [Float] {
        var result: [Float] = []
        let capacity = AVAudioFrameCount(frames + 2048)
        while true {
            guard let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else {
                throw AACDecoderError("no output buffer")
            }
            var error: NSError?
            let status = converter.convert(to: target, error: &error) { _, inputStatus in feed.next(inputStatus) }
            if status == .error { throw AACDecoderError("decode failed: \(error.map { "\($0)" } ?? "unknown")") }
            let produced = Int(target.frameLength) * channels
            if produced > 0 {
                result += UnsafeBufferPointer(start: target.floatChannelData![0], count: produced)
            }
            // Full buffer: there may be more; otherwise the decoder ran dry (or ended).
            if status != .haveData || target.frameLength < capacity { break }
        }
        return result
    }

    /// Hands the converter one buffer, then "no data now" (or end of stream). Used synchronously
    /// inside `convert(to:)`, hence the unchecked Sendable.
    private final class Feed: @unchecked Sendable {
        private var buffer: AVAudioCompressedBuffer?
        private let endOfStream: Bool

        init(_ buffer: AVAudioCompressedBuffer?, endOfStream: Bool) {
            self.buffer = buffer
            self.endOfStream = endOfStream
        }

        func next(_ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if let buffer {
                self.buffer = nil
                status.pointee = .haveData
                return buffer
            }
            status.pointee = endOfStream ? .endOfStream : .noDataNow
            return nil
        }
    }
}
