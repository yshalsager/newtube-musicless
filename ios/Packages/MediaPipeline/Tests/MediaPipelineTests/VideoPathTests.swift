import AVFoundation
import Foundation
import Testing
import os
@testable import MediaPipeline

/// US-013: the picture on the voices' clock, seeks, the background, and the segment cache; US-017's
/// recovery from a wall.
@Suite(.serialized) struct VideoPathTests {
    // MARK: Segment cache and prefetch

    @Test func cacheEvictsTheLeastRecentlyUsedSegmentOnly() {
        let cache = SegmentCache(capacity: 300)
        cache.store(0, Data(count: 100))
        cache.store(1, Data(count: 100))
        cache.store(2, Data(count: 100))
        _ = cache.segment(0)  // 0 is now the most recent
        cache.store(3, Data(count: 100))
        #expect(cache.contains(0) && !cache.contains(1) && cache.contains(2) && cache.contains(3))
        #expect(cache.byteCount == 300)
        cache.store(4, Data(count: 1_000))  // larger than the capacity: kept alone, never evicts itself
        #expect(cache.contains(4) && cache.byteCount == 1_000)
    }

    @Test func cachedSegmentsAreServedWithoutARequestAndPrefetchRunsAhead() async throws {
        let file = try TwoSegmentFile(itag: 160)
        let stub = MediaStub()
        stub.serve { request in .partial(file.body, request) }
        var configuration = MediaFetcherConfiguration()
        configuration.firstChunk = 4_096  // the header alone, so both segments need requests
        let fetcher = MediaFetcher(file: file.mediaFile, session: stub.session, hosts: MediaHostBook(), network: FakeNetwork(),
                                   configuration: configuration)
        let header = try await FMP4Reader.open(fetcher, initRange: file.initRange, indexRange: file.indexRange)
        let cache = SegmentCache(capacity: 1 << 20)

        var iterator = FMP4Reader.segments(fetcher, header: header, from: 0, cache: cache, prefetch: true).makeAsyncIterator()
        let first = try #require(try await iterator.next())
        #expect(first.index == 0 && first.data == file.segments[0])
        // Segment 1's request starts as soon as segment 0 is handed out, before the next pull.
        try await Self.eventually { stub.requests.count == 3 }
        let second = try #require(try await iterator.next())
        #expect(second.index == 1 && second.data == file.segments[1])
        #expect(try await iterator.next() == nil)

        let before = stub.requests.count
        var again: [Int] = []
        for try await segment in FMP4Reader.segments(fetcher, header: header, from: 0, cache: cache) { again.append(segment.index) }
        #expect(again == [0, 1])
        #expect(stub.requests.count == before, "both segments came from the cache")
    }

    // MARK: Engine with video (real renderers on the Mac, audio muted)

    @Test func thePictureStartsWithTheVoicesAtTheEditListsTimeZero() async throws {
        let rig = try PlayerRig(video: true)
        await rig.player.start(at: 0)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        let snapshot = await rig.player.snapshot()
        #expect((snapshot.videoAheadSeconds ?? 0) >= 0.25, "the hold waited for the picture too (\(snapshot))")
        let first = try #require(rig.videoLines.first { $0.hasPrefix("video first-frame reason=start") })
        // YouTube's H.264 starts at PTS 512/15360 with an edit list of 512: frame 0 shows at 0.00 (D44).
        #expect(first.contains(" at=0.00 ") && first.contains(" hidden=0 "), "\(first)")
        #expect(rig.videoLines.contains { $0.hasPrefix("video open itag=160 codec=avc1 size=256x144") && $0.contains("edit=512") })
        await rig.player.close()
    }

    @Test func aSeekStartsThePictureAtTheKeyframeAndHidesFramesBeforeTheTarget() async throws {
        let rig = try PlayerRig(video: true)
        await rig.player.start(at: 0)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        await rig.player.seek(to: 6)  // inside video segment 1, which starts at 4.03 s
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        let line = try #require(rig.videoLines.first { $0.hasPrefix("video first-frame reason=seek") })
        let hidden = try #require(Self.field("hidden", in: line).flatMap(Int.init))
        let at = try #require(Self.field("at", in: line).flatMap(Double.init))
        #expect(line.contains(" segment=1 "), "\(line)")
        #expect(hidden >= 55 && hidden <= 62, "frames 4.03–6.0 s decode but don't show (\(line))")
        // The first displayable frame in decode order: with B-frames, a reference frame up to a few
        // frames past the target comes before the target's own frame (also shown).
        #expect(at >= 6 && at < 6.14, "the first shown frames are the target's (\(line))")
        let position = await rig.player.snapshot().position
        #expect(position >= 6 && position < 6.5)
        await rig.player.close()
    }

    @Test func theRemoveMusicSwitchLeavesThePictureAlone() async throws {
        let rig = try PlayerRig(video: true)
        await rig.player.start(at: 1)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        let frames = rig.videoLines.filter { $0.hasPrefix("video first-frame") }.count
        let requests = rig.videoStub?.requests.count
        await rig.player.setRemoveMusic(false)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        #expect(rig.videoLines.filter { $0.hasPrefix("video first-frame") }.count == frames, "no video restart")
        #expect(rig.videoStub?.requests.count == requests, "no video refetch")
        await rig.player.close()
    }

    @Test func theBackgroundStopsThePictureAndTheForegroundCatchesItUp() async throws {
        let rig = try PlayerRig(video: true)
        await rig.player.start(at: 0)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        await rig.player.setVideoActive(false)
        #expect(await rig.player.snapshot().videoActive == false)
        let requests = rig.videoStub?.requests.count
        try await Task.sleep(for: .milliseconds(1_300))  // the voices play on; video is neither fetched nor fed
        let background = await rig.player.snapshot()
        #expect(background.status == .playing && background.position > 1.0, "\(background)")
        #expect(rig.videoStub?.requests.count == requests)

        await rig.player.setVideoActive(true)
        try await rig.eventually { rig.videoLines.contains { $0.hasPrefix("video caught-up") } }
        let resumed = try #require(rig.videoLines.first { $0.hasPrefix("video first-frame reason=resume") })
        let at = try #require(Self.field("at", in: resumed).flatMap(Double.init))
        let hidden = try #require(Self.field("hidden", in: resumed).flatMap(Int.init))
        #expect(hidden > 20, "frames from the keyframe up to the playhead are hidden (\(resumed))")
        #expect(at > background.position, "the first shown frame is ahead of the playhead (\(resumed))")
        #expect(await rig.player.snapshot().status == .playing, "the voices never stopped")
        await rig.player.close()
    }

    @Test func aQualitySwitchCatchesTheNewFileUpWithoutStoppingTheVoices() async throws {
        let rig = try PlayerRig(video: true)
        await rig.player.start(at: 0)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        try await Task.sleep(for: .milliseconds(1_200))
        // The "other quality" is the same 144p file at another URL (a new answer's link for it).
        let pictures = try TwoSegmentFile(itag: 160)
        let stub = MediaStub()
        stub.serve { request in .partial(pictures.body, request) }
        let fetcher = MediaFetcher(file: pictures.mediaFile, session: stub.session, hosts: MediaHostBook(), network: FakeNetwork())
        try await rig.player.switchVideo(to: pictures.source, fetcher: fetcher)
        try await rig.eventually { rig.videoLines.contains { $0.hasPrefix("video first-frame reason=quality") } }
        let line = try #require(rig.videoLines.first { $0.hasPrefix("video first-frame reason=quality") })
        #expect((Self.field("hidden", in: line).flatMap(Int.init) ?? 0) > 20, "catches up from the keyframe (\(line))")
        #expect(stub.requests.count >= 1, "the new file is read")
        #expect(await rig.player.snapshot().status == .playing, "the voices never stopped")
        await rig.player.close()
    }

    // MARK: 403 recovery (US-017)

    @Test func aWallRefusalIsRecoveredOnceForBothTracksAndPlaybackCarriesOn() async throws {
        let refusals = LockedRefusals()
        let audio = try TwoSegmentFile(), pictures = try TwoSegmentFile(itag: 160)
        var freshAudio = audio.mediaFile, freshVideo = pictures.mediaFile
        freshAudio.url = URL(string: audio.mediaFile.url.absoluteString + "&id=fresh")!
        freshVideo.url = URL(string: pictures.mediaFile.url.absoluteString + "&id=fresh")!
        let recovered = RecoveredFiles(audio: freshAudio, video: freshVideo)
        let rig = try PlayerRig(video: true, syntheticWall: 4) { refusal in
            refusals.append(refusal)
            try? await Task.sleep(for: .milliseconds(200))  // the recovery walk
            return recovered
        }
        await rig.player.start(at: 0)
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        try await rig.eventually { rig.lines.contains { $0.hasPrefix("wall-swap") } && rig.videoLines.count > 1 }
        try await Task.sleep(for: .milliseconds(500))
        let all = refusals.all
        #expect(all.count == 1, "one recovery for the open, both tracks served by it (\(all))")
        let first = try #require(all.first)
        #expect(first.forbiddenMs >= 4_000, "refused at the first segment past the wall (\(first))")
        #expect(first.lowestServedMs == 0 && first.highestServedMs < 4_000, "the open's served requests (\(first))")
        #expect(rig.lines.contains { $0.hasPrefix("wall-swap") && $0.contains("repointed=y") })
        #expect(await rig.player.snapshot().status == .playing, "no failure, no rewind")
        #expect(!rig.lines.contains { $0.hasPrefix("voices failed") })
        // The 23 KB picture came whole with its header request; the audio's segment 1 was refused.
        #expect(first.track == .audio)
        let freshRequests = rig.audioStub.requests.filter { $0.url?.query?.contains("id=fresh") == true }
        #expect(!freshRequests.isEmpty, "the refused segment was read again from the new URL")
        await rig.player.close()
    }

    @Test func withoutACopyOfTheFileTheVoicesSwitchToTheReplacementAtThePlayhead() async throws {
        let audio = try TwoSegmentFile()
        // Another file to the recovery: same bytes, but another lmt (an encode the old answer didn't have).
        var other = audio.mediaFile
        other.lastModified = "1701"
        other.url = URL(string: audio.mediaFile.url.absoluteString + "&id=other")!
        let stub = MediaStub()
        stub.serve { request in .partial(audio.body, request) }
        let replacementFetcher = MediaFetcher(file: other, session: stub.session, hosts: MediaHostBook(), network: FakeNetwork())
        let replacement = RecoveredFiles(audio: .replacement(FMP4Source(file: other, initRange: audio.initRange, indexRange: audio.indexRange),
                                                             replacementFetcher), video: nil)
        let rig = try PlayerRig(syntheticWall: 4) { _ in replacement }
        await rig.player.start(at: 0)
        try await rig.eventually { rig.lines.contains { $0.hasPrefix("voices switch-audio itag=140") } }
        try await rig.eventually { await rig.player.snapshot().status == .playing }
        #expect(!rig.lines.contains { $0.hasPrefix("voices failed") })
        #expect(!stub.requests.isEmpty, "the replacement file is read")
        await rig.player.close()
    }

    // MARK: Helpers

    static func field(_ name: String, in line: String) -> String? {
        line.split(separator: " ").first { $0.hasPrefix("\(name)=") }.map { String($0.dropFirst(name.count + 1)) }
    }

    static func eventually(timeout: Duration = .seconds(5), _ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !(await condition()) {
            guard ContinuousClock.now < deadline else {
                Issue.record("condition not met within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

final class LockedRefusals: Sendable {
    private let storage = OSAllocatedUnfairLock(initialState: [MediaRefusal]())
    func append(_ refusal: MediaRefusal) { storage.withLock { $0.append(refusal) } }
    var all: [MediaRefusal] { storage.withLock { $0 } }
}
