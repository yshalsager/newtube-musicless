import AudioToolbox
import CoreMedia
import Foundation

/// CoreMedia objects for the renderers (US-011): format descriptions from the init segment, and
/// sample buffers whose timing comes from the fragment.
public enum FMP4CoreMediaError: Error, Sendable, Equatable {
    case status(String, OSStatus)
    case notSupported(String)
}

extension FMP4Track {
    /// Video: from SPS/PPS (`CMVideoFormatDescriptionCreateFromH264ParameterSets`). Audio: AAC with
    /// the ES_Descriptor as magic cookie.
    public func formatDescription() throws -> CMFormatDescription {
        switch kind {
        case .video:
            let sets = sequenceParameterSets + pictureParameterSets
            var description: CMFormatDescription?
            let status = sets.withUnsafeDataPointers { pointers, sizes in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: Int32(nalLengthSize), formatDescriptionOut: &description)
            }
            guard status == noErr, let description else { throw FMP4CoreMediaError.status("video format", status) }
            return description
        case .audio:
            guard let cookie = elementaryStreamDescriptor, let config = audioSpecificConfig,
                  let fields = FMP4Demuxer.audioSpecificConfigFields(config) else { throw FMP4CoreMediaError.notSupported("audio config") }
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Double(fields.sampleRate), mFormatID: kAudioFormatMPEG4AAC,
                mFormatFlags: AudioFormatFlags(fields.objectType == 2 ? 2 : fields.objectType),  // kMPEG4Object_AAC_LC = 2
                mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
                mChannelsPerFrame: UInt32(fields.channels), mBitsPerChannel: 0, mReserved: 0)
            var description: CMFormatDescription?
            let status = cookie.withUnsafeBytes { raw in
                CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
                                               magicCookieSize: raw.count, magicCookie: raw.baseAddress,
                                               extensions: nil, formatDescriptionOut: &description)
            }
            guard status == noErr, let description else { throw FMP4CoreMediaError.status("audio format", status) }
            return description
        case .other:
            throw FMP4CoreMediaError.notSupported("track kind")
        }
    }

    /// The AAC encoder priming the edit list asks to skip (§4.2: ≈ 48 ms, or the voices run late).
    public var priming: CMTime { CMTime(value: max(0, editMediaTime), timescale: CMTimeScale(timescale)) }

    /// One compressed sample as a CMSampleBuffer: PTS, DTS and duration in the track timescale; a
    /// video sample that isn't a sync sample is marked `NotSync` (and `DependsOnOthers`).
    public func sampleBuffer(_ sample: FMP4Sample, format: CMFormatDescription) throws -> CMSampleBuffer {
        let length = sample.data.count
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: length, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard status == noErr, let block else { throw FMP4CoreMediaError.status("block buffer", status) }
        status = sample.data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length)
        }
        guard status == noErr else { throw FMP4CoreMediaError.status("block copy", status) }

        let scale = CMTimeScale(timescale)
        var timing = CMSampleTimingInfo(duration: CMTime(value: CMTimeValue(sample.duration), timescale: scale),
                                        presentationTimeStamp: CMTime(value: sample.presentationTime, timescale: scale),
                                        decodeTimeStamp: CMTime(value: sample.decodeTime, timescale: scale))
        var size = length
        var buffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
                                           sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &buffer)
        guard status == noErr, let buffer else { throw FMP4CoreMediaError.status("sample buffer", status) }
        if kind == .video && !sample.isSync {
            Self.setAttachment(kCMSampleAttachmentKey_NotSync, on: buffer)
            Self.setAttachment(kCMSampleAttachmentKey_DependsOnOthers, on: buffer)
        }
        return buffer
    }

    /// Decoded but not shown: frames between a seek's keyframe and its target (PRD §4.2), and frames
    /// already late while the picture catches up after the background.
    public static func markDoNotDisplay(_ buffer: CMSampleBuffer) {
        setAttachment(kCMSampleAttachmentKey_DoNotDisplay, on: buffer)
    }

    private static func setAttachment(_ key: CFString, on buffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: true),
              CFArrayGetCount(attachments) > 0 else { return }
        let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dictionary, Unmanaged.passUnretained(key).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
}

private extension Array where Element == Data {
    /// Pointers to every element's bytes, valid inside `body`.
    func withUnsafeDataPointers<R>(_ body: (UnsafePointer<UnsafePointer<UInt8>>, UnsafePointer<Int>) -> R) -> R {
        let copies = map { data -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: Swift.max(data.count, 1))
            data.copyBytes(to: pointer, count: data.count)
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = map(\.count)
        return pointers.withUnsafeBufferPointer { p in sizes.withUnsafeBufferPointer { s in body(p.baseAddress!, s.baseAddress!) } }
    }
}
