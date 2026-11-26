import AVFoundation
import Foundation
import MediaPipeline
import MusiclessCore

/// Who goes first on the one model runtime (US-028, Android's rule): the player's windows go
/// straight in; a download's window waits until no player window is in flight, so it only fills the
/// gaps between them.
actor ModelGate {
    private var playerWindows = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    func playerBegins() { playerWindows += 1 }

    func playerEnds() {
        playerWindows = max(0, playerWindows - 1)
        guard playerWindows == 0 else { return }
        let waiters = idleWaiters
        idleWaiters = []
        waiters.forEach { $0.resume() }
    }

    func waitUntilPlayerIdle() async {
        guard playerWindows > 0 else { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }
}

/// The runtime seen through the gate: `.player` for playback, `.download` for offline separation.
struct GatedBackend: SeparationBackend {
    enum Lane { case player, download }
    let runtime: ModelRuntime
    let gate: ModelGate
    let lane: Lane

    func separate(_ block: [Float], passThrough: Bool, submittedAt: ContinuousClock.Instant) async throws -> SeparatedWindow {
        switch lane {
        case .player:
            await gate.playerBegins()
            do {
                let window = try await runtime.separate(block, passThrough: passThrough, submittedAt: submittedAt)
                await gate.playerEnds()
                return window
            } catch {
                await gate.playerEnds()
                throw error
            }
        case .download:
            await gate.waitUntilPlayerIdle()
            return try await runtime.separate(block, passThrough: passThrough, submittedAt: submittedAt)
        }
    }

    func acquire() async { await runtime.acquire() }
    func release() async { await runtime.release() }
}

struct DownloadError: Error, CustomStringConvertible {
    let description: String
}

/// A file's audio with the music removed (US-028; PRD: AVAssetReader → Separator → AAC-LC 128 kb/s
/// with AVAssetWriter). If any window fails, the whole thing fails: a file with music or silence is
/// never written.
enum OfflineSeparator {
    static var pcmSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVSampleRateKey: 44_100.0, AVNumberOfChannelsKey: 2,
    ] }
    static var aacSettings: [String: Any] { [
        AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
    ] }

    static func run(input: URL, output: URL, backend: SeparationBackend, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: input)
        guard try await asset.loadTracks(withMediaType: .audio).first != nil else { throw DownloadError(description: "no audio track") }
        let totalFrames = max(1, try await asset.load(.duration).seconds * 44_100)
        let separator = Separator(backend: backend, log: { AppLog.musicless.info($0 + " offline=y") })
        try await separator.configure(sampleRate: 44_100, channels: 2)
        try? FileManager.default.removeItem(at: output)
        defer { Task { await separator.close() } }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await feed(input, into: separator) }
            group.addTask { try await write(from: separator, to: output, totalFrames: totalFrames, progress: progress) }
            try await group.waitForAll()
        }
    }

    /// The file's audio, decoded, into the separator (it suspends while 2 windows are outstanding).
    private static func feed(_ url: URL, into separator: Separator) async throws {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        output.alwaysCopiesSampleData = false
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? DownloadError(description: "the audio reader didn't start") }
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let samples = floats(buffer)
            if !samples.isEmpty { await separator.enqueue(samples) }
        }
        if reader.status == .failed { throw reader.error ?? DownloadError(description: "the audio reader failed") }
        await separator.endOfStream()
    }

    /// The voices, in order, into an AAC-LC file; any silence window fails the whole file.
    private static func write(from separator: Separator, to url: URL, totalFrames: Double,
                              progress: @Sendable (Double) -> Void) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: aacSettings)
        input.expectsMediaDataInRealTime = false
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? DownloadError(description: "the writer didn't start") }
        writer.startSession(atSourceTime: .zero)
        let format = try PCMSampleBuffers.format()
        while let chunk = await separator.nextChunk() {
            try Task.checkCancellation()
            if chunk.isEndOfStream { break }
            if chunk.isSilence {
                writer.cancelWriting()
                throw DownloadError(description: "separation failed")
            }
            var offset = 0
            while offset < chunk.frameCount {
                while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
                let count = min(PCMSampleBuffers.framesPerBuffer, chunk.frameCount - offset)
                let time = CMTime(value: chunk.startFrame + Int64(offset), timescale: 44_100)
                guard input.append(try PCMSampleBuffers.make(chunk.voices, offset: offset, frames: count, at: time, format: format)) else {
                    throw writer.error ?? DownloadError(description: "the writer refused audio")
                }
                offset += count
            }
            progress(min(1, Double(chunk.startFrame + Int64(chunk.frameCount)) / totalFrames))
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? DownloadError(description: "the writer didn't finish") }
    }

    static func floats(_ buffer: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        _ = samples.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        return samples
    }
}

/// One MP4 from the picture and an audio file, without re-encoding (AVAssetExportPresetPassthrough).
enum Muxer {
    static func mux(video: URL?, audio: URL, to output: URL) async throws {
        let composition = AVMutableComposition()
        let audioAsset = AVURLAsset(url: audio)
        guard let audioTrack = try await audioAsset.loadTracks(withMediaType: .audio).first,
              let compositionAudio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw DownloadError(description: "no audio to mux") }
        try compositionAudio.insertTimeRange(try await mediaRange(audioTrack), of: audioTrack, at: .zero)
        if let video {
            let videoAsset = AVURLAsset(url: video)
            guard let videoTrack = try await videoAsset.loadTracks(withMediaType: .video).first,
                  let compositionVideo = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { throw DownloadError(description: "no picture to mux") }
            try compositionVideo.insertTimeRange(try await mediaRange(videoTrack), of: videoTrack, at: .zero)
            compositionVideo.preferredTransform = try await videoTrack.load(.preferredTransform)
        }
        try? FileManager.default.removeItem(at: output)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw DownloadError(description: "no export session")
        }
        if #available(iOS 18, *) {
            try await export.export(to: output, as: .mp4)
        } else {
            export.outputURL = output
            export.outputFileType = .mp4
            await export.export()
            if let error = export.error { throw error }
        }
    }

    /// The track's time range, ending at its last sample. AVFoundation reads YouTube's fragmented
    /// video files at twice their length (the range runs on with the last frame held: 18.93 s of
    /// "Me at the zoo" reads 37.87 s, 634.57 s of Big Buck Bunny 1269.13 s; ffprobe and the samples
    /// agree on the real end), and a passthrough export copies that frozen tail into the file.
    static func mediaRange(_ track: AVAssetTrack) async throws -> CMTimeRange {
        let range = try await track.load(.timeRange)
        guard let cursor = track.makeSampleCursorAtLastSampleInDecodeOrder() else { return range }
        // The latest presentation among the last samples in decode order (B-frames reorder them).
        var end = CMTime.zero
        for _ in 0..<32 {
            end = max(end, cursor.presentationTimeStamp + cursor.currentSampleDuration)
            if cursor.stepInDecodeOrder(byCount: -1) == 0 { break }
        }
        guard end.isNumeric, end > range.start, end < range.end else { return range }
        return CMTimeRange(start: range.start, end: end)
    }
}
