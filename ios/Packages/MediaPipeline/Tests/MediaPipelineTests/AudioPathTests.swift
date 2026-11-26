import AVFoundation
import Foundation
import Testing
import os
@testable import MediaPipeline

/// US-012: the pieces between the demuxer and the renderer.
@Suite(.serialized) struct AudioPathTests {
    // MARK: HoldDebounce (Android's MusiclessHoldTest.debounceIgnoresShortAudioTrackGaps)

    @Test func debounceIgnoresShortGaps() {
        var hold = HoldDebounce()
        let zero = ContinuousClock.now
        func at(_ ms: Int) -> ContinuousClock.Instant { zero + .milliseconds(ms) }
        func update(_ starved: Bool, _ ms: Int) -> Bool { hold.update(starved: starved, now: at(ms)) }
        var now = 0
        // Android's emulator log showed 10 starvation gaps of 0–18 ms in 200 ms after an underrun.
        for _ in 0..<10 {
            #expect(!update(true, now))
            #expect(!update(true, now + 18))
            #expect(!update(false, now + 20))
            now += 20
        }
        #expect(!hold.holding)
        #expect(!update(true, now))
        #expect(update(true, now + 100))
        #expect(hold.holding && hold.since == at(now))
        #expect(!update(true, now + 5_000))
        #expect(update(false, now + 5_001))
        #expect(!hold.holding)
        hold.set(true, now: at(7))
        #expect(update(false, 8))
    }

    @Test func levelBlocksCompareTheSameSpanAcrossRates() {
        // A full-scale square wave is 0 dBFS; half amplitude is -6 dB. 48 kHz mono maps onto the 44.1 kHz timeline.
        var levels = LevelBlocks()
        let loud = (0..<48_000).map { $0 % 2 == 0 ? Float(1) : -1 }
        let quiet = (0..<48_000).map { $0 % 2 == 0 ? Float(0.5) : -0.5 }
        levels.add(loud, channels: 1, scale: 44_100.0 / 48_000)
        levels.add(quiet, channels: 1, scale: 44_100.0 / 48_000)
        #expect(levels.decibels(0..<40_000) == "0.0")
        #expect(levels.decibels(49_152..<88_000) == "-6.0", "spans round out to whole 4,096-frame blocks")
        #expect(PlayerEngine.decibels([0.5, -0.5, 0.5, -0.5]) == "-6.0")
        #expect(PlayerEngine.decibels([0, 0]) == "-inf")
    }

    // MARK: AAC decoding

    @Test func streamingDecodeMatchesOneBatchAndKeepsEveryFrame() throws {
        let track = try #require(try FMP4Demuxer.parseInit(FMP4Tests.data("140-init.mp4")).audio)
        let packets = try ["140-seg0.m4s", "140-seg1.m4s"].flatMap { try FMP4Demuxer.parseSegment(FMP4Tests.data($0), track: track) }

        let whole = try AACDecoder(track: track)
        #expect(whole.sampleRate == 44_100 && whole.channels == 2)
        let reference = try whole.decode(packets) + whole.finish()

        let streaming = try AACDecoder(track: track)
        var pieces: [Float] = []
        for start in stride(from: 0, to: packets.count, by: 97) {  // batches that don't line up with segments
            pieces += try streaming.decode(Array(packets[start..<min(start + 97, packets.count)]))
        }
        pieces += try streaming.finish()

        #expect(reference.count == packets.count * 1024 * 2, "one frame out per frame in (no trim, DECISIONS D42)")
        #expect(pieces.count == reference.count)
        var maxError: Float = 0
        for (a, b) in zip(pieces, reference) { maxError = max(maxError, abs(a - b)) }
        #expect(maxError == 0, "streaming in batches decodes the same samples (max error \(maxError))")
    }

    // MARK: Reader

    @Test func openReadsInitIndexAndTheFirstSegmentInOneRequest() async throws {
        let file = try TwoSegmentFile()
        let stub = MediaStub()
        stub.serve { request in .partial(file.body, request) }
        let fetcher = MediaFetcher(file: file.mediaFile, session: stub.session, hosts: MediaHostBook(), network: FakeNetwork())
        let header = try await FMP4Reader.open(fetcher, initRange: file.initRange, indexRange: file.indexRange)
        #expect(stub.requests.count == 1)
        #expect(header.index.references.count == 2)
        #expect(header.track(.audio)?.codec == "mp4a")
        #expect(header.prefixOffset == file.indexRange.upperBound + 1)
        #expect(header.prefix.count == 256 * 1024 - Int(header.prefixOffset), "the rest of the first 256 KiB")

        var segments: [FMP4Segments.Segment] = []
        for try await segment in FMP4Reader.segments(fetcher, header: header, from: 0) { segments.append(segment) }
        #expect(segments.map(\.index) == [0, 1])
        #expect(segments[0].data == file.segments[0])
        #expect(segments[1].data == file.segments[1])
        #expect(stub.requests.count == 2, "segment 0 came with the header; only segment 1's remainder was fetched")
        let remainder = try #require(MediaStub.parseRange(stub.requests[1]))
        #expect(remainder.lowerBound == 256 * 1024 && remainder.upperBound == Int64(file.body.count - 1))

        var fromSecond: [Int] = []
        for try await segment in FMP4Reader.segments(fetcher, header: header, from: 1) {
            fromSecond.append(segment.index)
            #expect(segment.data == file.segments[1])
        }
        #expect(fromSecond == [1])
    }

    // MARK: Player (real renderer, muted; fake voice stage)

    @Test func startHoldsThenPlaysAndSeekRestartsAtTheTarget() async throws {
        let rig = try PlayerRig()
        await rig.player.start(at: 0)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        #expect(rig.holds.first?.hasPrefix("hold reason=start waitInputMs=") == true)
        #expect(rig.lines.contains { $0.hasPrefix("voices first-audio ms=") })
        try await Task.sleep(for: .milliseconds(600))
        let position = await rig.player.snapshot().position
        #expect(position > 0.3 && position < 1.2, "the clock runs from 0 (at \(position))")

        await rig.player.seek(to: 12)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        let afterSeek = await rig.player.snapshot().position
        #expect(afterSeek >= 12 && afterSeek < 12.4, "restarts at the target, inside segment 1 (at \(afterSeek))")
        try await rig.eventually { rig.holds.contains { $0.hasPrefix("hold reason=seek ") } }

        await rig.player.seek(to: 19.4)
        try await rig.eventually(timeout: .seconds(4)) { await rig.player.snapshot().status == .ended }
        #expect(rig.lines.contains { $0.hasPrefix("voices end-of-stream") })
        await rig.player.close()
        #expect(await rig.stage.closed)
    }

    @Test func aSlowWindowHoldsTheClockInsteadOfLosingAudio() async throws {
        // 0.5 s chunks; the second takes 1.5 s, so the first runs out and the player must hold.
        let rig = try PlayerRig(chunkFrames: 22_050, delays: [1: .milliseconds(1_500)])
        await rig.player.start(at: 0)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        try await rig.eventually { await rig.player.snapshot().status == .holding(.underrun) }
        let held = await rig.player.snapshot()
        #expect(held.position <= 0.5 && held.aheadSeconds > 0, "held before the 0.5 s queued ran out (\(held))")
        try await Task.sleep(for: .milliseconds(300))
        #expect(await rig.player.snapshot().position == held.position, "rate 0 freezes the clock")
        try await rig.eventually(timeout: .seconds(3)) { await rig.player.snapshot().status == .playing }
        try await rig.eventually { rig.holds.contains { $0.hasPrefix("hold reason=underrun ") } }
        let line = try #require(rig.holds.first { $0.hasPrefix("hold reason=underrun ") })
        let total = try #require(line.split(separator: " ").last.flatMap { Int($0.dropFirst("totalMs=".count)) })
        #expect(total > 500 && total < 2_000, "\(line)")
        await rig.player.close()
    }

    @Test func theRemoveMusicSwitchFlushesAtTheCurrentPosition() async throws {
        let rig = try PlayerRig()
        await rig.player.start(at: 3)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        try await Task.sleep(for: .milliseconds(400))
        let before = await rig.player.snapshot().position
        await rig.player.setRemoveMusic(false)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        let after = await rig.player.snapshot()
        #expect(!after.removeMusic)
        #expect(abs(after.position - before) < 0.2, "same place, before \(before) after \(after.position)")
        #expect(await rig.stage.passThroughFlushes == [nil, false, true], "configure, start, switch")
        await rig.player.close()
    }

    @Test func anAudioDelayDropsThatMuchFromTheStartAndKeepsTime() async throws {
        // 0.5 s of declared-nowhere delay: the voices at time 0 are the file's samples from 0.5 s.
        let rig = try PlayerRig(audioDelay: 0.5)
        await rig.player.start(at: 0)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        let track = try #require(try FMP4Demuxer.parseInit(FMP4Tests.data("140-init.mp4")).audio)
        let decoder = try AACDecoder(track: track)
        let reference = try decoder.decode(FMP4Demuxer.parseSegment(FMP4Tests.data("140-seg0.m4s"), track: track))
        let skip = 22_050 * 2
        #expect(await rig.stage.firstInput == Array(reference[skip..<(skip + 200)]))
        #expect(rig.lines.contains { $0.hasPrefix("voices first-audio") && $0.contains(" at=0.00 ") })
        #expect(rig.lines.contains { $0.contains("delayMs=500.0") })
        await rig.player.close()
    }

    @Test func aRefusedSegmentFailsWithTheRecoveryHint() async throws {
        let rig = try PlayerRig(refuseFrom: 200_000)  // segment 1's remainder is refused
        await rig.player.start(at: 0)
        try await rig.eventually {
            if case .failed(let message) = await rig.player.snapshot().status { return message.contains("US-017") }
            return false
        }
        await rig.player.close()
    }
}

// MARK: - Fixtures

/// A Big Buck Bunny fixture as a two-segment file: init, a sidx rewritten to reference only the two
/// recorded segments, then the segments. itag 140: AAC, ≈ 20 s, 324 KB; itag 160: H.264 144p,
/// 0–4.03 s and 4.03–8.37 s, 23 KB.
struct TwoSegmentFile {
    let body: Data
    let segments: [Data]
    let initRange: ClosedRange<Int64>
    let indexRange: ClosedRange<Int64>
    let mediaFile: MediaFile

    init(itag: Int = 140) throws {
        let initData = try FMP4Tests.data("\(itag)-init.mp4")
        let sidx = try Self.truncatedIndex(FMP4Tests.data("\(itag)-index.sidx"), references: 2)
        segments = try [FMP4Tests.data("\(itag)-seg0.m4s"), FMP4Tests.data("\(itag)-seg1.m4s")]
        body = initData + sidx + segments[0] + segments[1]
        initRange = 0...Int64(initData.count - 1)
        indexRange = Int64(initData.count)...Int64(initData.count + sidx.count - 1)
        let url = URL(string: "https://rr1---sn-edge0aaa.googlevideo.com/videoplayback?itag=\(itag)&clen=\(body.count)&mn=sn-edge0aaa")!
        mediaFile = MediaFile(itag: itag, lastModified: "1700", contentLength: Int64(body.count), url: url)
    }

    var source: FMP4Source { FMP4Source(file: mediaFile, initRange: initRange, indexRange: indexRange) }

    /// The sidx with `reference_count` cut to `references` (version 0 or 1; first_offset stays 0).
    static func truncatedIndex(_ data: Data, references: Int) throws -> Data {
        var bytes = [UInt8](data)
        let version = bytes[8]
        let countOffset = version == 0 ? 30 : 38
        let size = countOffset + 2 + references * 12
        try #require(bytes.count >= size)
        bytes = Array(bytes[0..<size])
        bytes[0] = UInt8(size >> 24 & 0xFF); bytes[1] = UInt8(size >> 16 & 0xFF)
        bytes[2] = UInt8(size >> 8 & 0xFF); bytes[3] = UInt8(size & 0xFF)
        bytes[countOffset] = UInt8(references >> 8 & 0xFF); bytes[countOffset + 1] = UInt8(references & 0xFF)
        return Data(bytes)
    }
}

/// An engine on the two-segment files with a fake stage (and, with `video`, the 144p file on a
/// display layer's renderer), collecting its lines.
final class PlayerRig: Sendable {
    let player: PlayerEngine
    let stage: FakeStage
    /// Kept alive for its renderer; never touched after init.
    nonisolated(unsafe) let layer: AVSampleBufferDisplayLayer?
    let videoStub: MediaStub?
    let audioStub: MediaStub
    private let collected = LockedLines()
    var lines: [String] { collected.lines.filter { !$0.hasPrefix("hold ") } }
    var holds: [String] { collected.lines.filter { $0.hasPrefix("hold ") } }
    var videoLines: [String] { collected.lines.filter { $0.hasPrefix("video ") } }

    init(chunkFrames: Int = 44_100, delays: [Int: Duration] = [:], refuseFrom: Int64? = nil, video: Bool = false,
         audioDelay: Double = 0, syntheticWall: Double? = nil, recover: PlayerEngine.Recover? = nil) throws {
        let file = try TwoSegmentFile()
        let stub = MediaStub()
        stub.serve { request in
            if let refuseFrom, let start = MediaStub.rangeStart(request), start >= refuseFrom { return .status(403) }
            return .partial(file.body, request)
        }
        let fetcher = MediaFetcher(file: file.mediaFile, session: stub.session, hosts: MediaHostBook(), network: FakeNetwork())
        audioStub = stub
        var input: VideoInput?
        if video {
            let pictures = try TwoSegmentFile(itag: 160)
            let stub = MediaStub()
            stub.serve { request in .partial(pictures.body, request) }
            // A standalone renderer never asks for data on the Mac; a layer's does, on screen or not.
            let layer = AVSampleBufferDisplayLayer()
            self.layer = layer
            videoStub = stub
            input = VideoInput(source: pictures.source, fetcher: MediaFetcher(file: pictures.mediaFile, session: stub.session,
                                                                              hosts: MediaHostBook(), network: FakeNetwork()),
                               renderer: layer.sampleBufferRenderer)
        } else {
            layer = nil
            videoStub = nil
        }
        stage = FakeStage(chunkFrames: chunkFrames, delays: delays)
        var configuration = PlayerEngine.Configuration()
        configuration.muted = true
        configuration.audioDelay = audioDelay
        configuration.syntheticWallSeconds = syntheticWall
        let sink = collected
        player = PlayerEngine(audio: file.source, fetcher: fetcher, stage: stage, video: input, configuration: configuration,
                              recover: recover, log: { sink.append($0) }, holdLog: { sink.append($0) })
    }

    func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout); status \(await player.snapshot().status)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

final class LockedLines: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [String]())
    func append(_ line: String) { storage.withLock { $0.append(line) } }
    var lines: [String] { storage.withLock { $0 } }
}

/// Identity "separation" in fixed-size chunks; chunk n of a generation takes `delays[n]` after the
/// consumer asks for it. Input is taken without backpressure (the file is only 20 s).
actor FakeStage: VoiceStage {
    let chunkFrames: Int
    let delays: [Int: Duration]
    private(set) var generation = 0
    private(set) var closed = false
    private(set) var passThroughFlushes: [Bool?] = []
    private var pending: [Float] = []
    private var emittedFrames: Int64 = 0
    private var queue: [VoiceChunk] = []
    private var chunkIndex = 0
    private var waiter: CheckedContinuation<Void, Never>?
    private var stats = VoiceHoldStats()
    /// The first samples received since the last flush.
    private(set) var firstInput: [Float] = []

    init(chunkFrames: Int, delays: [Int: Duration]) {
        self.chunkFrames = chunkFrames
        self.delays = delays
    }

    func configure(sampleRate: Double, channels: Int) async throws {
        precondition(sampleRate == 44_100 && channels == 2, "the fixture is 44.1 kHz stereo")
        passThroughFlushes.append(nil)
        reset()
    }

    func flush(passThrough: Bool?) async -> Int {
        passThroughFlushes.append(passThrough)
        reset()
        return generation
    }

    private func reset() {
        generation += 1
        firstInput = []
        pending = []
        emittedFrames = 0
        queue = []
        chunkIndex = 0
        wake()
    }

    func enqueue(_ samples: [Float], generation token: Int) async {
        guard token == generation, !closed else { return }
        if stats.inputReadyAt == nil { stats.inputReadyAt = .now }
        if firstInput.count < 200 { firstInput += samples.prefix(200 - firstInput.count) }
        pending += samples
        while pending.count >= chunkFrames * 2 { cut(chunkFrames) }
        wake()
    }

    func endOfStream(generation token: Int) async {
        guard token == generation, !closed else { return }
        if !pending.isEmpty { cut(pending.count / 2) }
        queue.append(VoiceChunk(generation: generation, startFrame: emittedFrames, samples: [], isEndOfStream: true))
        wake()
    }

    private func cut(_ frames: Int) {
        queue.append(VoiceChunk(generation: generation, startFrame: emittedFrames,
                                samples: Array(pending[0..<(frames * 2)]), isEndOfStream: false))
        pending.removeFirst(frames * 2)
        emittedFrames += Int64(frames)
    }

    func nextChunk() async -> VoiceChunk? {
        while !closed {
            if let head = queue.first {
                let token = generation, index = chunkIndex
                if let delay = delays[index] { try? await Task.sleep(for: delay) }
                guard token == generation, !closed, !queue.isEmpty else { continue }
                chunkIndex = index + 1
                stats.inferMs = Int((delays[index] ?? .zero) / .milliseconds(1))
                _ = head
                return queue.removeFirst()
            }
            await withCheckedContinuation { waiter = $0 }
        }
        return nil
    }

    func beginHold() async { stats = VoiceHoldStats() }
    func holdStats() async -> VoiceHoldStats { stats }

    func close() async {
        closed = true
        wake()
    }

    private func wake() {
        waiter?.resume()
        waiter = nil
    }
}
