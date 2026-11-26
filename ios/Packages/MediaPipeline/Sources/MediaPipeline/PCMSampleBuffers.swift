import AudioToolbox
import CoreMedia
import Foundation

/// Voices as LPCM `CMSampleBuffer`s for `AVSampleBufferAudioRenderer` (US-012): interleaved Float32,
/// 44.1 kHz, stereo, the separation stage's output format.
public enum PCMSampleBuffers {
    public static let sampleRate: Int32 = 44_100
    /// Frames per buffer (≈ 0.37 s): small enough that the renderer's ~1–2 s of look-ahead is
    /// filled in steps and a flush throws little away.
    public static let framesPerBuffer = 16_384

    public static func format() throws -> CMAudioFormatDescription {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Double(sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8, mFramesPerPacket: 1,
            mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                                    magicCookieSize: 0, magicCookie: nil, extensions: nil,
                                                    formatDescriptionOut: &description)
        guard status == noErr, let description else { throw FMP4CoreMediaError.status("PCM format", status) }
        return description
    }

    /// `frames` interleaved stereo frames of `samples` starting at frame `offset`, presented at `time`.
    public static func make(_ samples: [Float], offset: Int, frames: Int, at time: CMTime,
                            format: CMAudioFormatDescription) throws -> CMSampleBuffer {
        let bytes = frames * 8
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw FMP4CoreMediaError.status("PCM block", status) }
        status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress! + offset * 8, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: bytes)
        }
        guard status == noErr else { throw FMP4CoreMediaError.status("PCM copy", status) }
        var buffer: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: time, packetDescriptions: nil, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw FMP4CoreMediaError.status("PCM sample buffer", status) }
        return buffer
    }
}
