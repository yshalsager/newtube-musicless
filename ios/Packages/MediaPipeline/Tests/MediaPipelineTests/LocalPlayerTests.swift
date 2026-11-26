import AVFoundation
import Foundation
import os
import Testing
@testable import MediaPipeline

/// US-027: a local file through the voice stage and the real audio renderer.
@Suite(.serialized) struct LocalPlayerTests {
    /// A 3 s AAC file (a 440 Hz tone at 44.1 kHz stereo), written with AVAssetWriter.
    static func writeTone(seconds: Double = 3) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "tone-\(UUID().uuidString).m4a")
        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000,
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let format = try PCMSampleBuffers.format()
        let total = Int(seconds * 44_100)
        var frame = 0
        while frame < total {
            let count = min(4_096, total - frame)
            var samples = [Float](repeating: 0, count: count * 2)
            for index in 0..<count {
                let value = Float(sin(2 * Double.pi * 440 * Double(frame + index) / 44_100)) * 0.3
                samples[index * 2] = value
                samples[index * 2 + 1] = value
            }
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            input.append(try PCMSampleBuffers.make(samples, offset: 0, frames: count,
                                                   at: CMTime(value: Int64(frame), timescale: 44_100), format: format))
            frame += count
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    @Test func aLocalFilePlaysThroughTheStageToItsEnd() async throws {
        let url = try await Self.writeTone()
        defer { try? FileManager.default.removeItem(at: url) }
        let stage = FakeStage(chunkFrames: 44_100, delays: [:])
        let lines = OSAllocatedUnfairLock(initialState: [String]())
        let engine = LocalPlayerEngine(url: url, stage: stage, video: nil, log: { line in lines.withLock { $0.append(line) } })
        await engine.start(at: 0, removeMusic: true)
        let opened = await engine.snapshot()
        #expect(opened.duration.map { abs($0 - 3) < 0.1 } == true)
        // It plays (the voices' clock moves), and stops at the end.
        var reachedPlaying = false
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            let snapshot = await engine.snapshot()
            if snapshot.status == .playing { reachedPlaying = true }
            if snapshot.status == .ended { break }
        }
        let end = await engine.snapshot()
        #expect(reachedPlaying)
        #expect(end.status == .ended && abs(end.position - 3) < 0.3, "ended at \(end.position) status \(end.status) ahead \(end.aheadSeconds) lines \(lines.withLock { $0 })")
        let input = await stage.firstInput
        #expect(input.count > 100 && input.prefix(200).contains { abs($0) > 0.05 }, "the decoded tone reached the stage")
        await engine.close()
        #expect(lines.withLock { $0 }.contains { $0.hasPrefix("local open file=m4a") })
    }

    @Test func aSeekRestartsTheStageAtTheTarget() async throws {
        let url = try await Self.writeTone()
        defer { try? FileManager.default.removeItem(at: url) }
        let stage = FakeStage(chunkFrames: 22_050, delays: [:])
        let engine = LocalPlayerEngine(url: url, stage: stage, video: nil)
        await engine.start(at: 0, removeMusic: false)
        try await Task.sleep(for: .milliseconds(300))
        await engine.seek(to: 2)
        try await Task.sleep(for: .milliseconds(300))
        let snapshot = await engine.snapshot()
        #expect(snapshot.position >= 1.9, "position \(snapshot.position)")
        #expect(await stage.passThroughFlushes.last == true, "Remove music off flushes to pass-through")
        await engine.close()
    }
}
