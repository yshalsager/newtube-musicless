import AVFoundation
import AVKit
import MediaPlayer
import Foundation
import MediaPipeline
import MusiclessCore
import Observation
import SwiftUI
import UIKit
import YouTubeEngine

/// The launch-flag checks that drive the player unattended (US-013 – US-018).
extension PlayerModel {
    /// US-013's seek measurement (`--seek-check`): 10 seeks spread over the video, each timed from the
    /// call until the voices and the picture play again, then 3 s of playback.
    func runSeekCheck() async {
        guard let engine, let duration = await engine.snapshot().duration, duration > 60 else {
            AppLog.player.info("seek-check needs a playing video longer than a minute")
            return
        }
        let fractions = [0.15, 0.62, 0.33, 0.81, 0.07, 0.48, 0.91, 0.26, 0.70, 0.40]
        var results: [Int] = []
        for (number, fraction) in fractions.enumerated() {
            let target = (duration * fraction).rounded()
            let start = ContinuousClock.now
            await engine.seek(to: target)
            var ready = false
            while ContinuousClock.now - start < .seconds(10) {
                if await engine.snapshot().status == .playing {
                    ready = true
                    break
                }
                try? await Task.sleep(for: .milliseconds(10))
            }
            let ms = Int((ContinuousClock.now - start) / .milliseconds(1))
            results.append(ready ? ms : 10_000)
            AppLog.player.info("seek-check n=\(number + 1) to=\(Int(target)) readyMs=\(ready ? "\(ms)" : "timeout")")
            try? await Task.sleep(for: .seconds(3))
        }
        let sorted = results.sorted()
        AppLog.player.info("seek-check done median=\((sorted[4] + sorted[5]) / 2) min=\(sorted.first!) max=\(sorted.last!) "
                           + "values=\(results.map(String.init).joined(separator: ","))")
    }

    /// US-013's background measurement (`--background-test`), unattended: 3 times, after 10 s of
    /// playback in the foreground, open the Files app so this one goes to the background (the voices
    /// play on), and wait for something to bring it back (`devicectl device process launch` without
    /// terminating it, from the Mac). The engine logs `video resume` and `video first-frame reason=resume`.
    func runBackgroundTest() async {
        for round in 1...3 {
            while UIApplication.shared.applicationState != .active || snapshot?.status != .playing {
                try? await Task.sleep(for: .milliseconds(200))
            }
            try? await Task.sleep(for: .seconds(10))
            AppLog.player.info("background-test round=\(round) leaving")
            await UIApplication.shared.open(URL(string: "shareddocuments://")!)
            while UIApplication.shared.applicationState == .active { try? await Task.sleep(for: .milliseconds(100)) }
            while UIApplication.shared.applicationState != .active { try? await Task.sleep(for: .milliseconds(100)) }
            AppLog.player.info("background-test round=\(round) back")
        }
        try? await Task.sleep(for: .seconds(5))
        AppLog.player.info("background-test done")
    }

    /// US-017's synthetic-wall check (`--wall-check`): 4 videos, each from 0:50 with its first
    /// answer's links refusing past 60 s of stream. A round passes when playback reaches 1:15 with no
    /// failure and no rewind (the position never goes back more than 0.2 s).
    func runWallCheck() async {
        var passed = 0
        for (round, preset) in Self.presets.enumerated() {
            await play(preset.id, at: 50)
            let start = ContinuousClock.now
            var highest = 0.0, rewind = false, result = "timeout"
            while ContinuousClock.now - start < .seconds(75) {
                try? await Task.sleep(for: .milliseconds(100))
                guard let snapshot else { continue }
                if case .failed = snapshot.status {
                    result = "failed"
                    break
                }
                if snapshot.position < highest - 0.2 { rewind = true }
                highest = max(highest, snapshot.position)
                if snapshot.position >= 75 {
                    result = rewind ? "rewind" : "ok"
                    break
                }
            }
            if result == "ok" { passed += 1 }
            AppLog.player.info("wall-check round=\(round + 1) video=\(preset.id) result=\(result) highest=\(String(format: "%.1f", highest)) "
                               + "rewind=\(rewind ? "y" : "n") error=\(error ?? "none")")
        }
        await stop(reason: "wall-check done")
        AppLog.player.info("wall-check done passed=\(passed)/\(Self.presets.count)")
    }

    /// US-018's `--system-check`: each speed against the clock, Now Playing and the remote-command
    /// handlers, the idle timer, full screen, then PiP started by leaving for the Files app (bring the
    /// app back with `devicectl … process launch` without `--terminate-existing`).
    func runSystemCheck() async {
        func log(_ line: String) { AppLog.player.info("system-check \(line) appState=\(AppActivity.logValue)") }
        func current() async -> PlayerEngine.Snapshot? { await engine?.snapshot() }
        func wait(_ seconds: Double) async { try? await Task.sleep(for: .milliseconds(Int(seconds * 1000))) }
        while snapshot?.status != .playing { await wait(0.2) }
        await wait(4)
        var passed = 0, total = 0
        func result(_ ok: Bool) -> String {
            total += 1
            if ok { passed += 1 }
            return ok ? "ok" : "failed"
        }

        // Speeds: the playhead's advance over 6 s of wall time.
        for value in [0.5, 1.5, 2, 1] as [Float] {
            await setSpeed(value)
            await wait(1)
            guard let start = await current() else { return }
            let began = ContinuousClock.now
            await wait(6)
            guard let end = await current() else { return }
            let measured = (end.position - start.position) / ((ContinuousClock.now - began) / .milliseconds(1) / 1000)
            let ok = abs(measured - Double(value)) / Double(value) < 0.05
            log("speed=\(value) measured=\(String(format: "%.3f", measured)) status=\(end.status) result=\(result(ok))")
        }

        // Now Playing (the system extrapolates the position from the last elapsed and rate), and the
        // handlers the remote commands call.
        func published() -> (elapsed: Double, rate: Double, info: [String: Any]) {
            let info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
            let rate = (info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue ?? -1
            let elapsed = (info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? NSNumber)?.doubleValue ?? -1
            return (elapsed + max(rate, 0) * NowPlaying.shared.secondsSincePublish, rate, info)
        }
        let now = published(), position = await current()?.position ?? 0
        let infoOK = now.info[MPMediaItemPropertyTitle] as? String == title && now.info[MPMediaItemPropertyArtist] != nil
            && now.info[MPMediaItemPropertyPlaybackDuration] != nil && abs(now.elapsed - position) < 1 && now.rate == 1
        log("now-playing title=\(now.info[MPMediaItemPropertyTitle] != nil ? "y" : "n") artist=\(now.info[MPMediaItemPropertyArtist] != nil ? "y" : "n") "
            + "artwork=\(now.info[MPMediaItemPropertyArtwork] != nil ? "y" : "n") duration=\(now.info[MPMediaItemPropertyPlaybackDuration] ?? "none") "
            + "elapsed=\(String(format: "%.2f", now.elapsed)) position=\(String(format: "%.2f", position)) rate=\(now.rate) "
            + "publishes=\(NowPlaying.shared.publishes) result=\(result(infoOK))")
        let idlePlaying = UIApplication.shared.isIdleTimerDisabled
        systemPause()
        await wait(1)
        let pausedRate = published().rate
        let paused = await current()
        let idlePaused = UIApplication.shared.isIdleTimerDisabled
        log("pause wantsToPlay=\(paused?.wantsToPlay ?? true) rate=\(pausedRate) idleTimerOff=\(idlePaused) "
            + "result=\(result(paused?.wantsToPlay == false && pausedRate == 0 && !idlePaused))")
        systemPlay()
        await wait(1.5)
        log("idle-timer playing=\(idlePlaying ? "off" : "on") paused=\(idlePaused ? "off" : "on") result=\(result(idlePlaying && !idlePaused))")
        let before = await current()?.position ?? 0
        systemSkip(10)
        await wait(2)
        let skipped = await current()?.position ?? 0
        log("skip from=\(String(format: "%.1f", before)) to=\(String(format: "%.1f", skipped)) result=\(result(skipped - before > 10 && skipped - before < 13.5))")
        systemSeek(to: 30)
        await wait(2)
        let sought = await current()?.position ?? 0
        log("scrub to=30 at=\(String(format: "%.1f", sought)) result=\(result(sought >= 30 && sought < 33.5))")

        // Full screen: the scene turns landscape, the layer fills it, and back.
        func orientation() -> String {
            guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first else { return "none" }
            return scene.effectiveGeometry.interfaceOrientation.isLandscape ? "landscape" : "portrait"
        }
        fullScreen = true
        await wait(3)
        let landscape = orientation(), bounds = layer?.bounds.size ?? .zero
        log("full-screen showing")
        await wait(2)
        log("full-screen orientation=\(landscape) layer=\(Int(bounds.width))x\(Int(bounds.height)) "
            + "result=\(result(landscape == "landscape" && bounds.width > bounds.height))")
        fullScreen = false
        await wait(3)
        let inline = layer?.superlayer != nil && (layer?.bounds.width ?? 0) < (layer?.bounds.height ?? 0) * 3
        log("full-screen closed orientation=\(orientation()) layer=\(Int(layer?.bounds.width ?? 0))x\(Int(layer?.bounds.height ?? 0)) "
            + "hosted=\(layer?.superlayer != nil) result=\(result(orientation() == "portrait" && inline))")
        await wait(2)

        // PiP: starts on its own as the app leaves; the picture keeps decoding while away.
        log("pip supported=\(AVPictureInPictureController.isPictureInPictureSupported()) controller=\(pip != nil) possible=\(pip?.isPossible == true)")
        await UIApplication.shared.open(URL(string: "shareddocuments://")!)
        while UIApplication.shared.applicationState == .active { await wait(0.1) }
        await wait(3)
        let started = pip?.isActive == true
        var aheads: [Double] = []
        let awayStart = await current()?.position ?? 0
        for _ in 0..<8 {
            await wait(1)
            if let now = await current() { aheads.append(now.videoActive ? now.videoAheadSeconds ?? 0 : -1) }
        }
        let awayEnd = await current()?.position ?? 0
        let decoding = !aheads.isEmpty && aheads.allSatisfy { $0 > 0 }
        log("pip started=\(started) videoAhead=\(aheads.map { String(format: "%.2f", $0) }) moved=\(String(format: "%.1f", awayEnd - awayStart)) "
            + "result=\(result(started && decoding && awayEnd - awayStart > 6))")
        log("waiting for the app to come back")
        while UIApplication.shared.applicationState != .active { await wait(0.2) }
        pip?.stop()
        await wait(3)
        log("back pip=\(pip?.isActive == true) status=\(snapshot.map { "\($0.status)" } ?? "none")")
        log("done passed=\(passed)/\(total)")
    }

    /// `--quality-check`: after 8 s of playback, step through every quality, 8 s each.
    func runQualityCheck() async {
        while snapshot?.status != .playing { try? await Task.sleep(for: .milliseconds(200)) }
        for option in qualities.reversed() + qualities.prefix(1) {
            try? await Task.sleep(for: .seconds(8))
            await setQuality(option)
        }
        try? await Task.sleep(for: .seconds(8))
        AppLog.player.info("quality-check done")
    }
}
