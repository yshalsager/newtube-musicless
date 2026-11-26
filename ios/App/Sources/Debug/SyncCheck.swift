import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import MediaPipeline
import os
import VideoToolbox

/// `--sync-check [<id>] [--sync-seconds <s>] [--sync-frames]` (US-013): where a sync test video's
/// beeps land against its marker frames on the engine's timeline. It fetches the first seconds of
/// the files the player would pick and times them the way the engine does: the video edit list
/// applied, the AAC not trimmed (D42). It finds the marker frames (a flash, or the tall waveform
/// some test cards draw in the beep frame) and the beep onsets, and pairs them.
///
/// The same audio is also decoded from YouTube's Opus file, whose WebM header states the encoder
/// delay (`CodecDelay`, OpusHead `pre_skip`). Comparing the two separates YouTube's unsignalled AAC
/// priming from the upload's own offset. `offset` = beep − marker: positive means the sound comes late.
enum SyncCheck {
    /// "Five minute sync test" (a sweep with "Bip!"/"Bop!" and a frame counter); cited in Mozilla bug 1132034.
    static let candidates = ["szoOsG9137U"]

    @MainActor
    static func run(videoID: String?, seconds: Double) async {
        let log: @Sendable (String) -> Void = { AppLog.player.info($0) }
        for id in videoID.map({ [$0] }) ?? candidates {
            do {
                try await check(id, seconds: seconds, log: log)
            } catch {
                log("sync-check video=\(id) failed: \(error)")
            }
        }
        log("sync-check done")
    }

    @MainActor
    private static func check(_ videoID: String, seconds: Double, log: @escaping @Sendable (String) -> Void) async throws {
        let media = try await VideoResolver.media(for: videoID, withVideo: true)
        guard let video = media.video else { return }
        log("sync-check video=\(videoID) title=\"\(media.title)\" picture=\"\(media.videoLabel ?? "?")\" "
            + "opus=\(media.opus.map { "\($0.itag)" } ?? "none")")
        let netLog: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
        async let aac = aacOnsets(media.audio, seconds: seconds, log: netLog)
        async let markers = videoMarkers(video, seconds: seconds, log: netLog)
        async let opus = opusOnsets(media.opus, seconds: seconds, log: netLog)
        let beeps = try await aac, frames = try await markers
        log("sync-check video=\(videoID) aacBeeps=\(beeps.count) [\(list(beeps))]")
        log("sync-check video=\(videoID) markers=\(frames.markers.count) [\(list(frames.markers))] frames=\(frames.count) "
            + "frameMs=\(String(format: "%.2f", frames.frameSeconds * 1000)) edit=\(frames.edit) kind=\(frames.kind)")
        if let vp9 = media.vp9 {
            // VP9 has no reordering, so its first block is frame 0: where WebM puts frame 0 on the clock.
            let fetcher = MediaFetcher(file: vp9, log: netLog)
            let head = try await fetcher.read(0...min(vp9.contentLength, 262_144) - 1)
            let blocks = (try? WebMOpus(head).blocks) ?? []
            log("sync-check video=\(videoID) vp9 itag=\(vp9.itag) firstBlockMs=\(blocks.first.map { String(format: "%.2f", $0.time * 1000) } ?? "?") "
                + "secondBlockMs=\(blocks.dropFirst().first.map { String(format: "%.2f", $0.time * 1000) } ?? "?") "
                + "(H.264 frame 0 after its edit list: \(frames.markers.first.map { String(format: "%.2f", $0 * 1000) } ?? "?"))")
        }
        report("aac-raw", beeps: beeps, markers: frames.markers, videoID: videoID, log: log)
        // What the engine plays: the AAC moved earlier by the delay it compensates (D44).
        report("aac-engine delayMs=\(String(format: "%.1f", media.audioDelay * 1000))", beeps: beeps.map { $0 - media.audioDelay },
               markers: frames.markers, videoID: videoID, log: log)
        do {
            if let reference = try await opus {
                log("sync-check video=\(videoID) opusBeeps=\(reference.onsets.count) [\(list(reference.onsets))] "
                    + "preSkip=\(reference.preSkip) codecDelayMs=\(String(format: "%.2f", reference.codecDelay * 1000)) "
                    + "decodedFrames=\(reference.decodedFrames) packets=\(reference.packets)")
                report("opus", beeps: reference.onsets, markers: frames.markers, videoID: videoID, log: log)
                let differences = beeps.compactMap { aacBeep in
                    reference.onsets.min(by: { abs($0 - aacBeep) < abs($1 - aacBeep) })
                        .flatMap { abs($0 - aacBeep) < 0.2 ? (aacBeep - $0) * 1000 : nil }
                }.sorted()
                if !differences.isEmpty {
                    let median = differences[differences.count / 2]
                    log("sync-check video=\(videoID) aacMinusOpusMs median=\(String(format: "%.2f", median)) "
                        + "samples44k=\(Int((median * 44.1).rounded())) min=\(String(format: "%.2f", differences.first!)) "
                        + "max=\(String(format: "%.2f", differences.last!)) n=\(differences.count)")
                }
            }
        } catch {
            log("sync-check video=\(videoID) opus failed: \(error)")
        }
    }

    /// `--delay-check [<id> …]`: how much later YouTube's AAC runs than its Opus, from any audio. The
    /// two files' level envelopes (1 ms steps, each on its own timeline: AAC decode times untrimmed,
    /// Opus block times minus `CodecDelay`) are cross-correlated over ±200 ms. A constant lag across
    /// videos is the AAC encoder's unsignalled delay.
    @MainActor
    static func runDelay(videoIDs: [String], seconds: Double) async {
        let log: @Sendable (String) -> Void = { AppLog.player.info($0) }
        let netLog: @Sendable (String) -> Void = { AppLog.netPath.info($0) }
        var lags: [Double] = []
        for id in videoIDs {
            do {
                let media = try await VideoResolver.media(for: id, withVideo: false)
                guard let opusFile = media.opus else {
                    log("delay-check video=\(id) no opus")
                    continue
                }
                async let aac = aacPCM(media.audio, seconds: seconds, log: netLog)
                async let opus = opusOnsets(opusFile, seconds: seconds, log: netLog)
                guard let reference = try await opus else { continue }
                let (lag, score) = envelopeLag(try await aac, reference.pcm)
                lags.append(lag)
                log("delay-check video=\(id) title=\"\(media.title)\" aacMinusOpusMs=\(String(format: "%.1f", lag)) "
                    + "correlation=\(String(format: "%.3f", score))")
            } catch {
                log("delay-check video=\(id) failed: \(error)")
            }
        }
        log("delay-check done lagsMs=[\(lags.map { String(format: "%.1f", $0) }.joined(separator: ","))]")
    }

    /// Lag in ms (positive = `a` later than `b`) maximising the correlation of the two envelopes,
    /// refined to 0.1 ms by fitting a parabola through the peak.
    static func envelopeLag(_ a: PCM, _ b: PCM) -> (Double, Double) {
        func envelope(_ pcm: PCM) -> [Double] {
            // Level per 1 ms step on an absolute grid (step i covers [i, i+1) ms).
            let first = Int((pcm.start * 1000).rounded(.up))
            var result: [Double] = []
            var ms = max(0, first)
            while true {
                let from = Int(((Double(ms) / 1000) - pcm.start) * pcm.rate), to = Int(((Double(ms + 1) / 1000) - pcm.start) * pcm.rate)
                guard from >= 0, to * pcm.channels <= pcm.samples.count else { break }
                var sum = 0.0
                for i in (from * pcm.channels)..<(to * pcm.channels) { sum += Double(pcm.samples[i] * pcm.samples[i]) }
                result.append(sqrt(sum / Double(max(1, (to - from) * pcm.channels))))
                ms += 1
            }
            return Array(repeating: 0, count: max(0, first)) + result
        }
        let x = envelope(a), y = envelope(b)
        let count = min(x.count, y.count) - 400
        guard count > 1_000 else { return (.nan, 0) }
        func score(_ lag: Int) -> Double {
            var dot = 0.0, xx = 0.0, yy = 0.0
            for i in 200..<(200 + count) {
                let u = x[i + lag], v = y[i]
                dot += u * v
                xx += u * u
                yy += v * v
            }
            return dot / max(1e-12, sqrt(xx * yy))
        }
        let scores = (-200...200).map { (lag: $0, value: score($0)) }
        let best = scores.max { $0.value < $1.value }!
        guard best.lag > -200, best.lag < 200 else { return (Double(best.lag), best.value) }
        let left = scores[best.lag + 199].value, right = scores[best.lag + 201].value
        let shift = (left - right) / (2 * (left - 2 * best.value + right))
        return (Double(best.lag) + (shift.isFinite ? shift : 0), best.value)
    }

    private static func report(_ label: String, beeps: [Double], markers: [Double], videoID: String,
                               log: @Sendable (String) -> Void) {
        let offsets = markers.compactMap { marker in
            beeps.min(by: { abs($0 - marker) < abs($1 - marker) }).flatMap { abs($0 - marker) < 0.4 ? ($0 - marker) * 1000 : nil }
        }
        guard !offsets.isEmpty else {
            log("sync-check video=\(videoID) \(label) no beep/marker pairs within 400 ms")
            return
        }
        let sorted = offsets.sorted()
        log("sync-check video=\(videoID) \(label) pairs=\(offsets.count) medianOffsetMs=\(String(format: "%.1f", sorted[sorted.count / 2])) "
            + "minMs=\(String(format: "%.1f", sorted.first!)) maxMs=\(String(format: "%.1f", sorted.last!)) (positive = sound late)")
    }

    private static func list(_ times: [Double]) -> String {
        times.prefix(12).map { String(format: "%.4f", $0) }.joined(separator: ",")
    }

    /// Segments of `source` covering the first `seconds`.
    private static func segments(_ source: FMP4Source, seconds: Double,
                                 log: @escaping @Sendable (String) -> Void) async throws -> (FMP4Header, [Data]) {
        let fetcher = MediaFetcher(file: source.file, log: log)
        let header = try await FMP4Reader.open(fetcher, initRange: source.initRange, indexRange: source.indexRange)
        var data: [Data] = []
        for try await segment in FMP4Reader.segments(fetcher, header: header, from: 0) {
            data.append(segment.data)
            if header.index.seconds(segment.reference.startTime + UInt64(segment.reference.duration)) >= seconds { break }
        }
        return (header, data)
    }

    // MARK: Beeps

    /// Decoded audio on its timeline: interleaved samples whose first frame is at `start` seconds.
    struct PCM: Sendable {
        var samples: [Float]
        var channels: Int
        var rate: Double
        var start: Double
    }

    /// AAC beep onsets on the engine's timeline (decode time / timescale, untrimmed as the engine plays it).
    static func aacOnsets(_ source: FMP4Source, seconds: Double, log: @escaping @Sendable (String) -> Void) async throws -> [Double] {
        let pcm = try await aacPCM(source, seconds: seconds, log: log)
        return onsets(pcm.samples, channels: pcm.channels, rate: pcm.rate, start: pcm.start)
    }

    static func aacPCM(_ source: FMP4Source, seconds: Double, log: @escaping @Sendable (String) -> Void) async throws -> PCM {
        let (header, data) = try await segments(source, seconds: seconds, log: log)
        guard let track = header.track(.audio) else { throw ResolveError(description: "no audio track") }
        let decoder = try AACDecoder(track: track)
        var pcm: [Float] = []
        var firstTime: Double?
        for segment in data {
            let samples = try FMP4Demuxer.parseSegment(segment, track: track)
            if firstTime == nil { firstTime = samples.first.map { Double($0.decodeTime) / Double(track.timescale) } }
            pcm += try decoder.decode(samples)
        }
        pcm += try decoder.finish()
        return PCM(samples: pcm, channels: decoder.channels, rate: decoder.sampleRate, start: firstTime ?? 0)
    }

    /// Onsets of interleaved PCM whose first frame is at `start` seconds: a ≈ 1 ms window (rate /
    /// 1000 samples) at least 15 dB above everything in the 80 windows before it and above -40 dBFS,
    /// at most one per 250 ms.
    static func onsets(_ pcm: [Float], channels: Int, rate: Double, start: Double) -> [Double] {
        let window = Int(rate / 1000)
        var levels: [Float] = []
        var index = 0
        while (index + window) * channels <= pcm.count {
            var sum: Float = 0
            for i in (index * channels)..<((index + window) * channels) { sum += pcm[i] * pcm[i] }
            levels.append(10 * log10(sum / Float(window * channels) + 1e-12))
            index += window
        }
        var found: [Double] = []
        var last = -1.0
        for i in 80..<max(80, levels.count) where levels[i] > -40 {
            let before = levels[(i - 80)..<(i - 1)].max() ?? -120
            let time = start + Double(i * window) / rate
            if levels[i] - before >= 15, time - last > 0.25 {
                found.append(time)
                last = time
            }
        }
        return found
    }

    // MARK: Opus reference

    struct OpusReference: Sendable {
        var onsets: [Double]
        var preSkip: Int
        var codecDelay: Double
        var decodedFrames: Int
        var packets: Int
        var pcm: PCM
    }

    /// The Opus file's beep onsets on its own timeline: block timestamps minus `CodecDelay` (the
    /// Matroska rule), so the first `pre_skip` decoded samples fall before 0.
    static func opusOnsets(_ file: MediaFile?, seconds: Double, log: @escaping @Sendable (String) -> Void) async throws -> OpusReference? {
        guard let file else { return nil }
        let fetcher = MediaFetcher(file: file, log: log)
        let length = min(file.contentLength, Int64(seconds * 24_000) + 65_536)  // ≈ 190 kbps worth, plus headers
        let data = try await fetcher.read(0...(length - 1))
        let webm = try WebMOpus(data)
        guard let first = webm.blocks.first else { throw ResolveError(description: "no Opus blocks") }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatOpus, mFormatFlags: 0, mBytesPerPacket: 0,
                                               mFramesPerPacket: 960, mBytesPerFrame: 0, mChannelsPerFrame: UInt32(webm.channels),
                                               mBitsPerChannel: 0, mReserved: 0)
        guard let input = AVAudioFormat(streamDescription: &asbd),
              let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                         channels: AVAudioChannelCount(webm.channels), interleaved: true),
              let converter = AVAudioConverter(from: input, to: output) else {
            throw ResolveError(description: "no Opus decoder")
        }
        var pcm: [Float] = []
        for block in webm.blocks {
            let compressed = AVAudioCompressedBuffer(format: input, packetCapacity: 1, maximumPacketSize: block.data.count)
            block.data.withUnsafeBytes { compressed.data.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
            compressed.packetDescriptions![0] = AudioStreamPacketDescription(mStartOffset: 0, mVariableFramesInPacket: 0,
                                                                             mDataByteSize: UInt32(block.data.count))
            compressed.packetCount = 1
            compressed.byteLength = UInt32(block.data.count)
            let target = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 5_760)!
            let feed = OneShot(compressed)
            var error: NSError?
            _ = converter.convert(to: target, error: &error) { _, status in
                if let buffer = feed.take() {
                    status.pointee = .haveData
                    return buffer
                }
                status.pointee = .noDataNow
                return nil
            }
            if let error { throw error }
            pcm += UnsafeBufferPointer(start: target.floatChannelData![0], count: Int(target.frameLength) * webm.channels)
        }
        let start = first.time - webm.codecDelay
        return OpusReference(onsets: onsets(pcm, channels: webm.channels, rate: 48_000, start: start), preSkip: webm.preSkip,
                             codecDelay: webm.codecDelay, decodedFrames: pcm.count / webm.channels, packets: webm.blocks.count,
                             pcm: PCM(samples: pcm, channels: webm.channels, rate: 48_000, start: start))
    }

    /// Hands one buffer to `convert(to:)` (called synchronously inside it).
    private final class OneShot: @unchecked Sendable {
        private var buffer: AVAudioCompressedBuffer?
        init(_ buffer: AVAudioCompressedBuffer) { self.buffer = buffer }
        func take() -> AVAudioCompressedBuffer? {
            defer { buffer = nil }
            return buffer
        }
    }

    // MARK: Markers

    struct Frames: Sendable {
        var markers: [Double]
        var count: Int
        var frameSeconds: Double
        var edit: Int64
        var kind: String
    }

    /// Marker frames on the engine's timeline (PTS minus the edit list), decoded by VideoToolbox:
    /// a flash (mean luma ≥ 40 above the median of the 8 frames before), or, for test cards that draw
    /// the sound's waveform, a frame whose band at 74–80 % of the height turns bright (the beep's
    /// tall waveform) after a quiet frame. At most one marker per 250 ms.
    static func videoMarkers(_ source: FMP4Source, seconds: Double, log: @escaping @Sendable (String) -> Void) async throws -> Frames {
        let (header, data) = try await segments(source, seconds: seconds, log: log)
        guard let track = header.track(.video) else { throw ResolveError(description: "no video track") }
        let format = try track.formatDescription()
        let edit = max(0, track.editMediaTime)
        var session: VTDecompressionSession?
        let attributes = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] as CFDictionary
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format, decoderSpecification: nil,
                                           imageBufferAttributes: attributes, outputCallback: nil,
                                           decompressionSessionOut: &session) == noErr, let session else {
            throw ResolveError(description: "no H.264 decoder")
        }
        defer { VTDecompressionSessionInvalidate(session) }
        let measured = OSAllocatedUnfairLock(initialState: [(time: Double, luma: Double, band: Double)]())
        var frameSeconds = 0.0
        for segment in data {
            for var sample in try FMP4Demuxer.parseSegment(segment, track: track) {
                sample.decodeTime -= edit
                frameSeconds = Double(sample.duration) / Double(track.timescale)
                let buffer = try track.sampleBuffer(sample, format: format)
                let time = Double(sample.presentationTime) / Double(track.timescale)
                VTDecompressionSessionDecodeFrame(session, sampleBuffer: buffer, flags: [], infoFlagsOut: nil) { status, _, image, _, _ in
                    guard status == noErr, let image else { return }
                    if saveFrames, time < 1.3 { save(image, time: time) }
                    let values = lumaFigures(image)
                    measured.withLock { $0.append((time, values.mean, values.band)) }
                }
            }
        }
        VTDecompressionSessionWaitForAsynchronousFrames(session)
        let frames = measured.withLock { $0 }.sorted { $0.time < $1.time }
        var flashes: [Double] = [], waves: [Double] = []
        var lastFlash = -1.0, lastWave = -1.0
        if let first = frames.first, first.band > 0.05 {
            waves.append(first.time)
            lastWave = first.time
        }
        for i in 1..<max(1, frames.count) {
            if i >= 8 {
                let previous = frames[(i - 8)..<i].map(\.luma).sorted()
                if frames[i].luma - previous[previous.count / 2] >= 40, frames[i].time - lastFlash > 0.25 {
                    flashes.append(frames[i].time)
                    lastFlash = frames[i].time
                }
            }
            if frames[i].band > 0.05, frames[i - 1].band < 0.02, frames[i].time - lastWave > 0.25 {
                waves.append(frames[i].time)
                lastWave = frames[i].time
            }
        }
        let useWaves = waves.count > flashes.count
        return Frames(markers: useWaves ? waves : flashes, count: frames.count, frameSeconds: frameSeconds, edit: edit,
                      kind: useWaves ? "waveform" : "flash")
    }

    /// `--sync-frames`: frames of the first 1.3 s as JPEG in Documents/sync, to see what marks the beep.
    static let saveFrames = ProcessInfo.processInfo.arguments.contains("--sync-frames")

    private static func save(_ image: CVImageBuffer, time: Double) {
        let directory = URL.documentsDirectory.appending(path: "sync")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = CIContext().jpegRepresentation(of: CIImage(cvImageBuffer: image),
                                                        colorSpace: CGColorSpaceCreateDeviceRGB()) else { return }
        try? data.write(to: directory.appending(path: String(format: "frame-%05.3f.jpg", time)))
    }

    /// Mean luma (every 8th pixel of every 8th row) and the share of bright pixels (> 128) in the
    /// band at 74–80 % of the height.
    private static func lumaFigures(_ image: CVImageBuffer) -> (mean: Double, band: Double) {
        CVPixelBufferLockBaseAddress(image, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(image, 0) else { return (0, 0) }
        let width = CVPixelBufferGetWidthOfPlane(image, 0), height = CVPixelBufferGetHeightOfPlane(image, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(image, 0)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0, count = 0
        for y in Swift.stride(from: 0, to: height, by: 8) {
            for x in Swift.stride(from: 0, to: width, by: 8) {
                sum += Int(bytes[y * stride + x])
                count += 1
            }
        }
        var bright = 0, band = 0
        for y in (height * 74 / 100)..<(height * 80 / 100) {
            for x in Swift.stride(from: 0, to: width, by: 2) {
                if bytes[y * stride + x] > 128 { bright += 1 }
                band += 1
            }
        }
        return (count > 0 ? Double(sum) / Double(count) : 0, band > 0 ? Double(bright) / Double(band) : 0)
    }
}

/// The few WebM (Matroska) elements an Opus audio file needs: TimecodeScale, the OpusHead in
/// CodecPrivate, CodecDelay, and each SimpleBlock or Block's time and payload. Truncated input is
/// fine: parsing stops at the first element that runs past the end.
struct WebMOpus {
    struct Block {
        var time: Double
        var data: Data
    }

    var channels = 2
    var preSkip = 0
    /// Seconds to subtract from every block time (Matroska `CodecDelay`).
    var codecDelay = 0.0
    var blocks: [Block] = []
    private var timecodeScale = 1_000_000.0
    private var clusterTime = 0.0

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        var index = 0
        walk(bytes, from: &index, to: bytes.count)
        guard !blocks.isEmpty else { throw ResolveError(description: "no WebM blocks") }
    }

    /// Segment, Tracks, TrackEntry, Info, Cluster, BlockGroup.
    private static let masters: Set<UInt64> = [0x1853_8067, 0x1654_AE6B, 0xAE, 0x1549_A966, 0x1F43_B675, 0xA0]

    private mutating func walk(_ bytes: [UInt8], from index: inout Int, to end: Int) {
        while index < end {
            guard let id = Self.vint(bytes, &index, keepMarker: true), let size = Self.vint(bytes, &index, keepMarker: false) else { return }
            let bodyEnd = size == UInt64.max ? end : index + Int(size)
            if Self.masters.contains(id) {
                if id == 0x1F43_B675 { clusterTime = 0 }
                walk(bytes, from: &index, to: min(bodyEnd, end))
                if bodyEnd > end { return }
                index = bodyEnd
                continue
            }
            guard bodyEnd <= end else { return }
            let body = Array(bytes[index..<bodyEnd])
            switch id {
            case 0x2A_D7B1: timecodeScale = Double(Self.uint(body))
            case 0x56AA: codecDelay = Double(Self.uint(body)) / 1e9
            case 0x63A2 where body.count >= 19 && body.starts(with: Array("OpusHead".utf8)):
                channels = Int(body[9])
                preSkip = Int(body[10]) | Int(body[11]) << 8
            case 0xE7: clusterTime = Double(Self.uint(body)) * timecodeScale / 1e9
            case 0xA3, 0xA1:
                var at = 0
                guard Self.vint(body, &at, keepMarker: false) != nil, at + 3 <= body.count else { break }
                let relative = Int16(bitPattern: UInt16(body[at]) << 8 | UInt16(body[at + 1]))
                guard body[at + 2] & 0x06 == 0 else { break }  // laced blocks don't occur in YouTube's Opus
                blocks.append(Block(time: clusterTime + Double(relative) * timecodeScale / 1e9, data: Data(body[(at + 3)...])))
            default: break
            }
            index = bodyEnd
        }
    }

    /// An EBML variable-length integer; `keepMarker` for element ids. All-ones sizes mean "unknown".
    private static func vint(_ bytes: [UInt8], _ index: inout Int, keepMarker: Bool) -> UInt64? {
        guard index < bytes.count, bytes[index] != 0 else { return nil }
        let length = bytes[index].leadingZeroBitCount + 1
        guard index + length <= bytes.count else { return nil }
        let mask = UInt8(0xFF >> length)
        var value = UInt64(keepMarker ? bytes[index] : bytes[index] & mask)
        var allOnes = bytes[index] & mask == mask
        for i in 1..<length {
            value = value << 8 | UInt64(bytes[index + i])
            allOnes = allOnes && bytes[index + i] == 0xFF
        }
        index += length
        return !keepMarker && allOnes ? UInt64.max : value
    }

    private static func uint(_ body: [UInt8]) -> UInt64 { body.reduce(0) { $0 << 8 | UInt64($1) } }
}
