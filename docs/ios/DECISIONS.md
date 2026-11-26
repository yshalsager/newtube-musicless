# iOS decisions

Every decision taken while building the iOS app, with its evidence. Numbering continues from the
PRD's §3 (D1–D10). When iOS deliberately behaves differently from the Android app, it is recorded
here too (`ios/CLAUDE.md`). Settled `[verify]` items from the PRD are at the end.

## Baseline

- Branch `ios/poc`, cut from `musicless` at `7ed92917`: the fork's tip, two commits past the
  `d074c0c6` the PRD was written from (`616e43d5`, `7ed92917`, small local-files follow-ups in
  `localmedia/` and `MobileBrowseActivity`). Neither touches Musicless code.
- Submodules initialised: `MediaServiceCore` at `52fecea0`, `SharedModules` at `25213805`.
- Toolchain (checked 2026-11-25): Xcode 26.4 (17E192), Swift 6.3, XcodeGen 2.46.0, Python 3.11.14,
  JDK 17.0.18. Matches PRD Appendix A.

## Phase 0

### D11. Minimum iOS 17.0 (closes Q7) — US-001

As D9 says. Nothing in Phase 0 needs more; the iOS 26 APIs the probe calls are behind `#available`
(`BGTaskScheduler.supportedResources` 26.0, `VTRegisterSupplementalVideoDecoderIfAvailable` 26.2).
**Evidence:** the app builds with deployment target 17.0 and runs on iOS 26.6.2 and the 26.4
simulator.

### D12. Where settings live: identity in xcconfig, structure in project.yml — US-001

- `Config/Base.xcconfig` (attached to the app target) holds the identity: `BUNDLE_ID_PREFIX`,
  `DEVELOPMENT_TEAM`, `PAID_TEAM`, `PRODUCT_BUNDLE_IDENTIFIER = $(BUNDLE_ID_PREFIX).musicless`,
  versions. It includes `Paid.xcconfig`, then the optional `Local.xcconfig` (`#include?`) last.
- `project.yml` holds the structure: `SWIFT_VERSION 6.0`, `SWIFT_STRICT_CONCURRENCY complete`,
  `TARGETED_DEVICE_FAMILY 1` (iPhone only), no Catalyst / Designed-for-iPhone on Mac or Vision.
- **Why:** XcodeGen writes its presets (for example `TARGETED_DEVICE_FAMILY "1,2"`) as target
  settings, which outrank a target's xcconfig. Settings that must win go in project.yml.
- **Evidence:** `xcodebuild -showBuildSettings` resolves `PRODUCT_BUNDLE_IDENTIFIER`,
  `DEVELOPMENT_TEAM`, `TARGETED_DEVICE_FAMILY = 1`, `SWIFT_VERSION = 6.0`,
  `SWIFT_STRICT_CONCURRENCY = complete`, `IPHONEOS_DEPLOYMENT_TARGET = 17.0`.
- App target `Musicless` → `Musicless.app` (the PRD §11 paths), display name "NewTube Musicless".
  The home screen truncates it ("NewTube Musi…"); kept as US-001 says.
- `App/Info.plist` is a committed, hand-written file. Not XcodeGen's `info:` (it rewrites the file
  on every generate) and not `GENERATE_INFOPLIST_FILE` (it can't carry custom keys such as
  `GitCommit` now, `UIBackgroundModes` and `MusiclessModelBaseURL` later).

### D13. Commit stamp: a post-build phase edits the processed Info.plist — US-001

- The "Stamp git commit" phase writes `git rev-parse --short HEAD` into the built Info.plist as
  `GitCommit`, with `-dirty` when `git status --porcelain -- ios/` is not empty, and `unknown` without
  git (a zip download). The placeholder screen and the probe show it.
- Its input file is `$(TARGET_BUILD_DIR)/$(INFOPLIST_PATH)`. **Evidence:** without it, the parallel
  build ran the phase before `ProcessInfoPlistFile`, which then overwrote the value: the app showed
  `commit=unknown`. With the input, the log orders `ProcessInfoPlistFile` (line 67) before the phase
  (line 134) and the app shows `7ed92917-dirty`.
- `ENABLE_USER_SCRIPT_SANDBOXING = NO` on the app target: the phase reads `.git` and edits the
  processed plist, both outside what a sandboxed phase may touch.
- "Based on dependency analysis" is off, so it runs every build. Xcode prints a *note* about it, not
  a warning (the result bundle counts 0 warnings).

### D14. The paid switch picks files by variable name — US-001

xcconfig has no conditionals, so `Paid.xcconfig` sets
`CODE_SIGN_ENTITLEMENTS = $(MUSICLESS_ENTITLEMENTS_$(PAID_TEAM))`, with `_NO` →
`App/Musicless.entitlements` and `_YES` → `App/MusiclessPaid.entitlements`. Both are empty in
Phase 0; Phase 1 adds the memory entitlements to the paid file. **Evidence:** with `PAID_TEAM = YES`,
`-showBuildSettings` gives `CODE_SIGN_ENTITLEMENTS = App/MusiclessPaid.entitlements`; the device build
signs with the paid team's wildcard profile ("iOS Team Provisioning Profile: *"), as expected with
no capability.

### D15. Free Personal Team test deferred to the first paid-only capability (Q8) — US-001

Phase 0 has no capability, so building with a free team now proves nothing. The test belongs with
the first paid-only entitlement (Increased Memory Limit, US-005/US-006). It also costs something:
a Personal Team can register only a few App IDs a week, and it needs a bundle id of its own (bundle
ids are global and the paid team now holds this one). Ask the developer before running it.

### D16. Packages: tools 6.0, Swift Testing, placeholder modules — US-001

- `swift-tools-version: 6.0`: Swift 6 language mode, so complete strict concurrency without flags.
  Platforms iOS 17 and macOS 14 (PRD §4.8).
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`). `swift test` and Xcode run them.
- Each package's placeholder is `public enum <Name>Module { static let name }` with one test. The app
  imports all three and shows their names, so the wiring is exercised from the first build.
- The scheme's test action lists the three package test targets.

### D17. Logging: one helper, Android's line formats, stdout mirror in Debug — US-002

- `AppLog` channels `Musicless`, `NetPath`, `Player` (PRD §11) plus `Probe`, all with subsystem =
  bundle id. Messages keep Android's text (`Window pipeline …`, `hold reason=…`) when those arrive.
- Debug builds mirror every line to stdout as `[<category>] <message>` through
  `FileHandle.standardOutput` (an unbuffered `write`). **Why:** OSLog never reaches
  `devicectl … --console`; `print` is buffered when the console isn't a terminal; and Swift 6
  rejects touching the C `stdout` global. **Evidence:** the device console shows the `[Probe]` lines.
- It lives in the app for now. When a package first logs (US-003/US-005), decide whether each
  package gets its own `Logger` or a small shared module.

### D18. `--run-probe` opens the probe at launch — US-002

So the report can be captured from the Mac with `devicectl … --console`, without touching the
phone. Used for `DEVICE-PROBE.md`.

### D19. Probe contents beyond the acceptance list — US-002

Added because later stories need them: `phys_footprint` (what jetsam compares with the limit, for
the 700 MB budget), CPU cores, Metal GPU, screen pixels and refresh rate, the probe's own duration,
and a "bare session" test that opens any decoder for a format description without codec
configuration. That test tells a software decoder from none, which `VTIsHardwareDecodeSupported`
can't (`-8971` = a decoder exists and wants its config atom; `-12906` = none).

The audio session is read inactive, then active with `.playback` / `.moviePlayback` and
`.mixWithOthers`, so probing doesn't stop whatever else is playing; it is deactivated with
`.notifyOthersOnDeactivation`.

### D20. App icon and accent colour from the Android fork's icon — US-001

- `ios/tools/render_app_icon.swift` draws `smarttubetv/src/musicless/res/drawable/ic_launcher_*.xml`
  (the emerald background, the white arch, the gold voice bars) to a 1024 px opaque PNG. It maps the
  middle 72 of the vector's 108 units (what Android launchers show) to the full icon.
- **Why now:** an icon set without an image makes actool warn, and the definition of done says zero
  warnings. The PRD's §8 asks for this conversion anyway.
- Accent: `#0E6B52` (the icon's emerald) in light, `#2EC48F` in dark, where `#0E6B52` is too dark
  to read. Placeholder until the UI phase. The app forces dark appearance (§8, "dark theme first").

### D21. A dedicated simulator — US-001

"Musicless iPhone 13 mini" (iOS 26.4), created with `simctl create`: the same screen as the test
phone. The Mac's only other simulator belongs to another project. Its id is local and not committed.

### D22. Device ids and tool quirks — US-001

- `devicectl` takes the CoreDevice identifier, `xcodebuild` the hardware UDID (PRD §11). Both live in
  the shell (`$DEVICE_ID`, `$IOS_UDID`), never in committed files.
- `xcrun xctrace list devices` lists the phone under "Devices Offline" while `devicectl` reports it
  "available (paired)" and `xcodebuild` builds and installs to it. Use
  `xcodebuild -showdestinations` to check a destination, not xctrace's state.
- Every `devicectl` command prints "Failed to load provisioning paramter list … No provider was
  found." It is harmless.

## Phase 1

### D23. DSP golden fixtures: integer-generated input, reduced F=512 — US-003

- `ios/tools/dsp-golden/` compiles the **unchanged** `MusiclessDsp.java` with `DspGolden.java` (same
  package) and writes little-endian float32 arrays plus `manifest.json` into MusiclessCore's test
  resources (`run.sh`; JDK 17).
- The input comes from integer arithmetic only (a sine table rounded to int16, phase accumulators,
  xorshift32 noise), so Swift regenerates it **bit for bit**; the manifest's FNV-1a hash of the int16
  stream proves it (the test fails if it ever drifts). The input itself isn't stored.
- F=64: full spectrum, magnitude and synthesis output. F=512: frames {0, 1, 2, 255, 256, 509/510,
  511, 512} and three output ranges, plus sum / sum of squares / max |x| over the full arrays. Full
  F=512 fixtures would be ~20 MB; these total 2.3 MB.
- The synthesis mask is `((c·7 + f·13 + k·31) mod 101) / 100`, exact in float in both languages.
- **Measured** (tolerance = the PRD's): spectrum max error 1.3e-7 of the peak (≤ 1e-3), magnitude
  2.2e-7 of the peak (≤ 1e-3), synthesis output 8.9e-8 absolute (≤ 1e-4), same at F=512. Float32
  vDSP clears the PRD's `[verify]` tolerances by four orders of magnitude.

### D24. The Swift DSP — US-003

- vDSP's packed real FFT (`vDSP_fft_zrip`, log2n 12) in Float32. Its forward output is twice the DFT
  (halved on store); fed true DFT values, its inverse returns the unnormalised IDFT, and Java's
  `/ FFT` is folded into the synthesis window. The Nyquist bin (packed in `imag[0]`) is zero, as
  Java zeroes bins ≥ 1024.
- The gain sums Float squares in Double, as Java does. Interior frames gather and overlap-add with
  strided vDSP calls; only the reflect-padded edge frames use scalar loops.
- `Dsp` owns its scratch (not thread-safe; one per executor); results are arrays (copy-on-write).
  The per-size setup (Hann² weights) is vectorised: it runs for every ramp window, on the path to the
  first voices (debug build, first 512 window: 242 → 46 ms).
- Mac (M4), release: analyze 4.3 ms + synthesize 4.4 ms for F=512, against 96 ms for the Java DSP.

### D25. Model store: streaming download, own gunzip, no auto-start yet — US-004

- Behaviour ported from `MusiclessModels.java`: `Range` resume; a 206 must carry
  `Content-Range: bytes <offset>-`; a 416 on resume means the gzip is complete; a server that
  ignores `Range` (200) restarts the file; 100 MB cap on the download and on each model; SHA-256
  (CryptoKit) streamed with the gunzip; atomic publish as `<sha>-<name>` (`rename(2)`); the partial
  file is deleted on any unpack or hash failure; errors read `Voice model: <message>`.
- The body streams through a per-task `URLSessionDataDelegate` into an `AsyncThrowingStream`, so the
  cap cancels mid-download. Gunzip: Apple's Compression `OutputFilter` (raw DEFLATE) after parsing the
  RFC 1952 header ourselves; the trailer's CRC-32 isn't checked because the SHA-256 covers it.
- Files live in Application Support/musicless, excluded from backup (directory and files; seen as
  the `com_apple_backup_excludeItem` attribute on the simulator).
- `ModelStore` is a main-actor `@Observable` (`notDownloaded`, `downloading(percent)`, `ready`,
  `failed(message)`, `start`/`retry`, `awaitReady`).
- **No download at launch yet** (superseded by D55: it starts at launch while Remove music is on).
  Android starts it at launch when Remove music is on; here a debug
  row (and `--download-models`) starts it until the Remove-music setting exists (US-014/US-024), so
  a debug build doesn't spend 36 MB of someone's data unasked.
- Verified with the real release: both files gunzip to the pinned hashes (Mac test `liveRelease`,
  and in the app on the simulator).

### D26. `MusiclessModelBaseURL` comes from xcconfig — US-004

`Base.xcconfig` sets `MUSICLESS_MODEL_BASE_URL` (written `https:/$()/…` because xcconfig treats `//`
as a comment); Info.plist reads it. Like Android's `musiclessModelBaseUrl` Gradle property, a builder
can point it elsewhere in `Local.xcconfig`; empty means "not configured".

### D27. ONNX Runtime 1.32.0 from Microsoft's NuGet package — US-005 (developer's decision)

- **Why:** the PRD's `[verify]` URL is dead. `microsoft/onnxruntime-swift-package-manager` and
  `microsoft/onnxruntime` return 404 on GitHub (pulled around 2026-11-17, per several mirrors), and
  `download.onnxruntime.ai`, where the Swift package fetched its binary, fails TLS (certificate for
  another host; checked with curl on 2026-11-25). Third-party mirrors exist; one of them carries a
  re-tagged `1.24.2` that differs from the commit four others agree on (`b7fb7f7`). The developer
  chose the official NuGet package over a mirror or skipping ORT.
- **Source:** `Microsoft.ML.OnnxRuntime` 1.32.0 on nuget.org (published 2026-11-13), 184 MB,
  SHA-256 `a9150bc2…5641db`. Its SHA-512 matches nuget.org's catalog; it carries Microsoft
  Corporation's author signature and NuGet.org's repository signature (not cryptographically verified
  here: that needs `dotnet nuget verify`).
- **Assembly** (`ios/tools/fetch_onnxruntime.sh`, run by `bootstrap.sh`; output gitignored in
  `Packages/MusiclessCore/Vendor/`): the package's `ios-arm64` and simulator frameworks (a static
  library, CoreML execution provider included) plus a module map, and a `macos-arm64` framework
  wrapping the package's osx-arm64 dylib for `swift test` on the Mac. That dylib's install name is
  changed, so its Microsoft signature is stripped and it is signed ad hoc; it never ships.
- The static library needs `libc++`, `libz`, `libsqlite3`, Core ML and UIKit (it reads `UIDevice`);
  Package.swift links them (UIKit on iOS only).
- Licences: the package's `LICENSE` and `ThirdPartyNotices.txt` are copied next to the xcframework for
  About (US-024).

### D28. ONNX Runtime through its C API — US-005

NuGet ships no Objective-C wrapper, so `OnnxSession` calls the C API (`OrtApi`, version 32) directly.
Session options match Android's: intra-op 2, inter-op 1, no CPU arena, no memory pattern,
`session.intra_op.allow_spinning=0`, basic optimisation, free dimension `num_splits` = 1; telemetry
off on the one process-wide environment. The CoreML execution provider gets `ModelFormat=MLProgram`,
`MLComputeUnits` = `ALL` or `CPUAndNeuralEngine`, and a `ModelCacheDirectory` so compiles are reused.

### D29. `ModelRuntime`: an actor on one serial queue — US-005

The actor's executor is a `DispatchSerialQueue` ("Musicless-ORT"), the counterpart of Android's single
model thread: loading, the whole window pipeline (DSP, both models, mask) and disposal run there, so
`cpuMs` is one thread's CPU time as on Android. Only the 512-frame `Dsp` is kept; ramp sizes are built
per use (Android's ~22 MB saving). Release after 120 s idle; a memory warning releases only when no
player holds the runtime (iOS has no `TRIM_MEMORY_UI_HIDDEN`; "idle" is the PRD's rule).

### D30. `Separator`: Android's grid behind an async API — US-005

- `configure(sampleRate:channels:)`, `enqueue(_:) async`, `endOfStream() async`,
  `flush(passThrough:)`, `close()`, and chunks pulled with `nextChunk()` (or `chunks`). Each chunk has
  its generation, start frame, voices, and flags for silence and end of stream.
- Backpressure: where Android's `queueInput` returns without consuming while 2 windows are
  outstanding, `enqueue` suspends; a flush or close wakes it, and it drops the rest of its samples
  (they belong to the old position).
- A flush drops queued windows at once (Android skips them when the worker reaches them); the running
  window keeps its slot until it returns and sees the new generation. Same bound, freed sooner.
- Failure: everything received and not yet taken comes out as silence, further input too, with the
  error in `failureMessage` and a log line; never the original audio. A flush clears it, as Android's
  `onFlush` does.
- Other rates and mono go through `AVAudioConverter` (PRD §4.3), with mono copied to both channels
  (`channelMap [0, 0]`) instead of mixed down.
- Every window logs Android's line: `Window pipeline ms=… processor=… generation=… window=… frames=…
  outputStartFrame=… outputFrames=… queueMs=… waitModelMs=… analyzeMs=… vocalsMs=… accompanimentMs=…
  maskMs=… synthesizeMs=… otherMs=… cpuMs=… backend=…`. `appState=` is the app's to append when
  playback logs it (Phase 2).

### D31. Backend names in logs — US-005

`backend=ort-cpu`, `ort-coreml-all` or `ort-coreml-ane` (the PRD wrote `ort-coreml`): the two CoreML
compute-unit settings behave differently enough (locked GPU failures) to need separate names.

### D32. End-to-end fixture: the Sintel trailer, not committed — US-005

- 30 s (15–45 s) of the Blender Foundation's Sintel trailer (CC BY 3.0), decoded once by `afconvert`.
  `ios/tools/separation_fixture.sh` downloads it (SHA-256 pinned), cuts it and runs
  `ios/tools/reference_two_models.py` (numpy + onnxruntime 1.32.0 from PyPI, in a venv under
  `ios/.vendor`). Clip and reference (16 MB) live in gitignored `ios/.fixtures/`, like the models;
  the licence, attribution and hashes are committed in `Tests/…/Fixtures/separation/LICENSE.md`.
- The Swift test runs when the models and the fixture are present and skips otherwise.
- **Measured: SNR 124.3 dB** against the Python reference on the Mac (max error 2.1e-6), 123.3 dB on
  the iOS simulator. The PRD's 35 dB threshold is easily met.

### D33. Benchmark method — US-006

A deterministic tone-and-noise signal instead of a bundled clip: the models do the same arithmetic
for any audio, and nothing has to be licensed or shipped. Timings come from a Release build (the
debug build's Swift loops are unoptimised); `--console-log` mirrors its log to stdout. Windows run
back to back (harder on thermals than playback, which waits ~12 s per window). The locked run waits
for the app to be backgrounded, so Auto-Lock can do the locking unattended. Results:
`docs/ios/BENCHMARKS.md`.

### D34. D-backend: ONNX Runtime on the CPU — US-006 (closes Q1)

ORT CPU: F=512 in 258 ms foreground and 264 ms locked (gate: 3,000 / 6,000 ms), first window 38 ms,
load 131 ms, peak 116 MB, and numerically identical to the reference. The CoreML execution provider
loads in 0.8–2.2 s, needs 284–1,827 ms for the first window of each shape and 450–570 MB, fails
every locked inference with `ALL` (no background GPU), and its `CPUAndNeuralEngine` sessions show no
sign of using the Neural Engine (thread CPU = wall time). **US-007 is skipped.** `InferenceBackend`
stays switchable for a later energy comparison.

### D35. Background audio and Files access now, not in Phases 2 and 5 — US-006

The locked benchmark needs `UIBackgroundModes: audio` (PRD: Phase 2) and its CSV in Files needs
`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` (PRD: Phase 5). Neither needs an
entitlement, so free Apple IDs still sign the app.

### D36. No Increased Memory Limit entitlement yet — US-006

PRD §4.6 lists Increased Memory Limit and Extended Virtual Addressing for Phase 1. They aren't added:
with ORT CPU, separation peaks at 116 MB while `os_proc_available_memory()` reports 2,088 MiB at
launch (DEVICE-PROBE.md), so they would buy nothing and would make the app need a paid team. Revisit
when playback (video + audio + separation, Phase 2) is measured against the 700 MB budget. The free
Personal Team test (Q8, D15) moves with them: there is still no paid-only capability to test.

## Phase 2

### D37. InnerTube requests: QueryBuilder's template, ported literally — US-008

- `ClientProfile` holds VISIONOS, TV_TIZEN, WEB_EMBED, ANDROID_VR, ANDROID_REEL and IOS, copied from
  MediaServiceCore `52fecea0` (2026-10-20) with the source of every value in comments.
- `PlayerRequestBody` builds the body the way `QueryBuilder.build()` does (a multi-line template,
  lines trimmed and joined, trailing object commas removed outside strings), so spacing quirks such
  as `"clientName": "…"` next to `"osName":"visionOS"` come out identical. The test compares the
  VISIONOS body with one reconstructed by hand from the Kotlin template, byte for byte.
- `acceptLanguage` is the BCP-47 tag (Android's `Locale.toLanguageTag()`, e.g. `en-US`), not the bare
  language code.
- Headers as `VideoInfoApi`: Content-Type, Origin, `X-Goog-Visitor-Id` (same visitor as the body), the
  client's UA, name id and version; no Referer, no Cookie, no key; 8 s timeout. One URLSession with no
  cookie jar and no cache.
- The visitor comes from `youtube.com/tv` with the Fire TV UA, replaying the stored
  `VISITOR_INFO1_LIVE` plus the SOCS consent cookie (`AppServiceInt`, including `nextVisitorCookie`'s
  rule that an answer without the cookie can't erase the identity); it persists for 10 h in
  Application Support. The signature timestamp comes from the TV player JS with
  `signatureTimestamp[:=](\d+)` (Android's `signatureTimestamp:(\d+)`, plus `=`), once per player
  URL, persisted; -1 when unknown.
- Every request logs `api client=… status=… ms=… protocol=…`. **On the iPhone (2026-11-25):** `tv`,
  `player-js` and every `/player` request ran over `h2`.

### D38. VISIONOS serves with `signatureTimestamp = -1` — US-008

- **/player, on the iPhone, 5 ordinary videos:** VISIONOS answered `OK` with the same adaptive
  formats, all with plain URLs (no cipher), SABR and HLS markers, whether the body carried the real
  timestamp (20779, player `b485e332`) or -1. So VISIONOS doesn't need the timestamp to *answer*.
  /player took 118–229 ms.
- **Media, on the iPhone over cellular (2026-11-25):** the first KiB of every answer's audio
  (Range header) came back **206 for 10 of 10 answers, 5 of 5 with -1**. VISIONOS needs no real
  timestamp; the engine still sends it when known, as Android does.
- **On the developer's home Wi-Fi the same probe timed out:** the googlevideo cache node YouTube
  assigned there refused TCP connections from the phone and the Mac alike, while
  `redirector.googlevideo.com` and other nodes answered, and the redirector sent the request back to
  the dead node. The official YouTube app played fine on that Wi-Fi at the same time, so its player
  gets around such a node.

### D39. googlevideo host fallback through the URL's `mn` nodes — for US-010

- **Evidence (iPhone, home Wi-Fi, 2026-11-25, 10 answers):** every assigned node timed out, and
  several different ones of the same local cache group did (`rrN---sn-<isp>-…`). Retrying the same
  signed URL on the URL's alternate node (`rrN---<other mn entry>.googlevideo.com`, same replica
  prefix) served **206 for 10 of 10**, with -1 timestamps too. Cellular reached the assigned nodes
  directly. Android has no such fallback (no `mn` or `redirector` handling in MediaServiceCore or
  the app), so it would stall on this network.
- **Plan for US-010:** the MediaFetcher retries a connection failure or timeout on the `mn`
  alternates, then remembers the dead node for the session, so later requests go straight to one that
  answers. It needs a short connect timeout on the first attempt (each fallback above first waited
  10 s, which would break G2's 2.5 s start): measure the value in US-010. This differs from Android
  on purpose; a 403 is still handled by re-resolving, never by changing hosts (PRD §0.4).

### D40. Answers: parsing, kinds and the pair to play — US-009

- `PlayerAnswer` decodes what Android's `VideoInfo` reads for playback (playability with reason,
  subreason and the age marker; video details; adaptive formats with ranges, length, `lastModified`,
  URL or cipher; the HLS, DASH and SABR URLs). Numbers may arrive as strings; both decode.
- `AnswerKind` is the per-answer verdict of LANES §2.2, ported from `VideoInfo`'s predicates and
  `BotCheckDetector` (the explicit bot words; the terminal allowlist in six locales, members-only
  openings, violation removals with their qualifier, "learn more" and region guards; Java's NFD
  normalisation as Foundation's decomposition minus non-base characters). Two additions: `noDelivery`
  for OK without fetchable formats (SABR-only), and `unavailable(status)` for ERROR and the other
  statuses no rule names. The lane-dependent rules (admitting anonymous TV_TIZEN, the age-gate stop,
  consensus) stay with the planner (US-015).
- `FormatSelector`: the best `video/mp4` avc1 at ≤ 60 fps whose **short side** is within the cap
  (a vertical 1080x1920 video is 1080p, as Android's quality fix in HANDOFF §38), preferring size,
  then frame rate, then bitrate; audio is the highest-bitrate `mp4a.40.2` at 44.1 kHz, else any mp4a.
- **Fixtures** were recorded on the iPhone (`--record-answers`) and scrubbed by `AnswerScrubber`: only
  `playabilityStatus`, `videoDetails` and `streamingData` are kept (visitor ids live in the dropped
  `responseContext`); the requester's IP, which googlevideo embeds in every URL (`ip=`, and
  `/ip/…/` in manifest paths), is replaced everywhere; the cache node names (`rrN---sn-…` hosts and
  the `mn=` list, which point at the requester's ISP) become `sn-scrubbed-<n>`, keeping the structure
  US-010's host fallback needs; and the country (`gcr=`) and opaque per-request tokens (`ei`, `bui`,
  `spc`, `xpc`, `svpuc`, signatures, throughput, timing) become `scrubbed`, in query and manifest-path
  form. A test re-checks every committed fixture. `fvip=` is a replica index, not an address. (The
  node names and the country slipped into the first local commit; it was amended before any push.) Videos age: the first made-for-kids and live candidates had become
  "removed by the uploader" and "live recording not available", so the recorder tries candidates
  per kind, and those two answers became extra terminal fixtures (7 in all, 142 KB).
- **On the iPhone:** 10 of 10 ordinary videos resolved with one VISIONOS request each (119–495 ms),
  picking 1080p avc1 where offered (60 fps for the 60 fps video) and itag 140 (AAC-LC 44.1 kHz).

### D41. The media fetcher — US-010

- `MediaFetcher` (MediaPipeline, no YouTube types: a `MediaFile` is itag + lmt + clen + URL) reads
  byte ranges through a `Range` header only, with `assumesHTTP3Capable`, on one cookie-less,
  cache-less media URLSession. Sequential reads (`chunks(from:)`, pull-based) start at 256 KiB after
  every start, seek or repoint and double to 2 MiB.
- **Measured on the iPhone (home Wi-Fi, 2026-11-25):** the first 256 KiB took 67–374 ms once a node
  was proven, against 712–1,980 ms for a 2 MiB first request; later 0.5–2 MiB chunks 74–488 ms; whole
  AAC files at 2.3–8.6 MiB/s. So the 256 KiB → 2 MiB ramp stays. googlevideo nodes spoke HTTP/1.1
  over TCP (curl on the Mac too) and h3 only occasionally; that's the server side.
- A 403 (or 401) is a typed `MediaRefused(itag, byteOffset, url, status)`, never retried on that URL.
  The caller maps the offset to stream time (sidx) for the wall rule (US-017), walks for a new answer,
  `repoint(to:)`s, and resumes from the offset. `repoint` only accepts the same file (itag, lmt, clen).
- Timeouts and 5xx get 3 retries with exponential backoff from 250 ms; a lost link
  (`networkConnectionLost`, `notConnectedToInternet`, …) waits on `NWPathMonitor` for a usable path
  first. A 200 for a partial range is an error (the server ignored `Range`).
- **Host fallback (D39), as built:** a node not yet seen answering on this network gets a 2 s idle
  timeout and, if still silent after 750 ms, its URL's next node (`mn`) starts in parallel; the first
  answer wins and the loser is cancelled and marked dead. Dead nodes, and the rest of their cluster
  (`sn-<cluster>-…`), go after the alternates until the network signature changes (then the book
  starts over: cellular reached the same cluster). Nodes that answered go first. Measured: a dead node
  costs ~0.75 s once per network; later videos go straight to working nodes.
- `NetworkWatcher` waits for `NWPathMonitor`'s first path before reporting a signature (up to 0.5 s):
  answering "unknown" first made the book take the real signature as a network change and forget
  what it had learned (seen on the device: the dead node was asked again).
- **Known limitation:** the race times a request's completion, not its first byte, so a large
  request to an unproven node can start a needless duplicate. The pipeline's first request to a node
  is small (256 KiB, init or index ranges), so it rarely matters; the fix would be a streaming task
  delegate that signals the response headers.

### D42. The fMP4 demuxer, and YouTube's AAC carries no priming signal — US-011

- `FMP4Demuxer` (MediaPipeline) parses the subset YouTube serves: ftyp + moov (`tkhd`, `edts/elst`,
  `mdhd`, `hdlr`, `stsd` with avc1/avc3 + avcC and mp4a + esds, `mvex/trex`), the sidx (byte ranges
  anchored after the box; `seek(to:)` maps a time to a reference), and moof (`tfhd` with every
  default, `tfdt`, `trun` with every flag, v0/v1 composition offsets) + mdat. `FMP4Track` builds the
  CoreMedia format descriptions (SPS/PPS; AAC with the ES_Descriptor as magic cookie) and one
  `CMSampleBuffer` per sample (PTS/DTS/duration in the track timescale; `NotSync` and
  `DependsOnOthers` on non-sync video samples).
- **Fixtures** (368 KB, CC BY 3.0): Big Buck Bunny as YouTube serves it, init + index + two
  segments of itag 140 (AAC-LC 44.1 kHz stereo, 64 references of 9.98 s) and itag 160 (H.264 144p,
  123 references), recorded on the iPhone with `--record-media`; media bytes and ranges only.
- Tests decode for real: the first H.264 sample through VideoToolbox (a 256-px frame) and 200 AAC
  packets through AVAudioConverter (204,800 stereo frames, not silent).
- **PRD §4.2 assumed the AAC priming is signalled by an edit list. YouTube's itag 140 has none:** its
  init holds no `edts`, and its `udta` only names the encoder ("Google"); no iTunSMPB-style gapless
  tag either. The video track does have an `elst`. Core Audio's AAC decoder trims nothing on its own
  (200 packets → exactly 200 × 1024 frames), and Android's media3 sees an encoder delay of 0 for these
  files, so it doesn't trim either. So `FMP4Track.priming` exposes `elst` when a file has one (local
  files, downloads), and is 0 here. Whether YouTube's audio then runs late against its video gets
  measured in US-013 with an A/V sync test video (limit 40 ms); a fixed trim is added only if the
  measurement asks for it.

### D43. The audio-only player — US-012

- **The chain, as built:** `VoicePlayer` (MediaPipeline, an actor on its own serial queue) reads the
  file with `FMP4Reader` and decodes it with `AACDecoder`. It runs the PCM through a `VoiceStage`
  (the Separator), turns the voices into LPCM `CMSampleBuffer`s, and plays them on an
  `AVSampleBufferAudioRenderer` attached to an `AVSampleBufferRenderSynchronizer`.
  - **FMP4Reader:** the first request takes the init range, the index range and the rest of the
    first 256 KiB. The opening 10 s segment (≈ 160 KB) usually comes with them: one round trip
    instead of three. After that it reads whole segments, in requests that double up to 2 MiB.
  - **AACDecoder:** `AVAudioConverter`, streaming with "no data now" so its state carries across
    segments. Its output keeps the track's own rate and channels; the Separator converts what isn't
    44.1 kHz stereo, so nothing is resampled twice.
  - **Sample buffers:** Float32 44.1 kHz stereo, 16,384 frames each (0.37 s).
- **`VoiceStage` is a protocol in MediaPipeline,** so the package needs no ONNX Runtime and its tests
  run the player with a fake stage. The app adapts the Separator to it (`SeparatorStage`). The
  Separator gained:
  - generation-checked `enqueue` and `endOfStream`, so a late call from an old position can't leak
    into the new one (the order of two actors' calls isn't guaranteed);
  - a `flush` that returns the new generation;
  - Android's hold fields: `beginHold()` and `holdStats` (`inputReadyNs`, `queueMs`,
    `waitModelMs`, `inferMs`).
- **Bounded look-ahead:** a voice chunk is taken from the stage only once the previous one is in the
  renderer. Memory holds one chunk (≤ 11.9 s) plus the stage's two windows. Android does the same:
  it drains processor output only after the AudioTrack has taken the previous output.
- **How the renderer behaves** (Mac probe, then the iPhone):
  - It accepts ≈ 1.1 s before `isReadyForMoreMediaData` turns false, and keeps 1.7–2.1 s queued
    while playing.
  - When it runs dry, the synchronizer's clock keeps running, so late voices would be lost. That's
    why a hold must set rate 0.
- **Hold:**
  - From a start or seek, rate 0 until the first voices are queued.
  - Later, a hold when less than 0.25 s is queued and more is coming, debounced 100 ms
    (`HoldDebounce`, ported with Android's test).
  - **Differs from Android:** a slow network holds too (`reason=underrun`; `waitInputMs` shows the
    wait for input), because nothing else stops this clock. On Android, ExoPlayer pauses for network
    buffering on its own.
  - The clock check sleeps until a hold could first be needed (queued time − 0.25 s): 2–4 wake-ups a
    second. It checks every 25 ms while debouncing, and every 250 ms while held or paused.
  - The `hold reason=start|seek|underrun waitInputMs=… queueMs=… waitModelMs=… inferMs=… totalMs=…`
    line keeps Android's format.
- **`delaysRateChangeUntilHasSufficientMediaData = false`:** our hold decides when the clock runs,
  without an unmeasured extra wait. At first audio (1.11 s queued),
  `hasSufficientMediaDataForReliablePlaybackStart` was already true anyway.
- **Seek and the Remove-music switch** do the same restart:
  - flush the renderer and the stage (switching pass-through);
  - fetch from the target's segment;
  - drop decoded frames before the target, so the voices start exactly there.
  - **Known gap:** the restart fetches bytes it already had (≈ 0.5 MB on a switch, 9–49 ms on Wi-Fi).
    A byte cache belongs to US-013, which measures seeks.
- **Automatic renderer flush** (an output change): the buffers not yet played are kept and
  re-enqueued from the flush time. A flush of our own goes first, which keeps them in order. This
  hasn't happened on the device yet.
- **Audio session:**
  - `.playback` / `.moviePlayback`, activated on play.
  - An interruption pauses playback and resumes it when iOS passes `shouldResume`.
  - Losing the output device (headphones unplugged) pauses.
  - Now Playing and remote commands are US-018.
- **Logs** (besides the hold line):
  - `voices chunk startS=… seconds=… inputDb=… voicesDb=…`: input and voices levels over the same
    span, so the drop in level is measured, not guessed;
  - `voices first-audio ms=…` (from `start`), `voices tap-to-first-audio ms=… playerMs=…`;
  - `voices position=…` every 10 s;
  - `appState=fg|bg` on these lines and on `Window pipeline`.
- **Test harness:**
  - the "Voices only" debug screen;
  - `--voices [<id>] [--voices-at <s>]`;
  - four presets: Big Buck Bunny (score, no speech), Sintel (dialogue over score), Kurzgesagt's
    "The Egg" (narration over music), and Rick Astley (a song).
  - US-014's watch screen replaces it.
- **Measured on the iPhone** (home Wi-Fi, Debug build, 2026-11-25):
  - **Tap to first voices:** 920–1,310 ms, against G2's 2.5 s. 362–532 ms of it is `/player`.
  - **The start hold:** 487–638 ms: input 293–389 ms, model load 124–172 ms, first window 53 ms.
  - **Switch holds:** 129–360 ms.
  - **F=512 windows:** 268–347 ms in this unoptimised build; D34 measured 258 ms in Release.
  - **After the start:** no hold while playing.
  - **Output:** the hardware runs at 48 kHz, and the renderer resamples.
- **Ear test** (the developer, on the iPhone): Big Buck Bunny with Remove music switched on and off
  several times. Music was gone with it on and back with it off. Levels over the same spans: voices
  10–34 dB below the input with it on, equal to it with it off. The score-only film keeps some animal
  and bird sounds: the vocals model keeps voice-like sounds, which aren't music.
- **Sintel's levels** (the lock run): its opening 33 s, score without dialogue, came out 40–59 dB below
  the input, which is silence. Its dialogue (34–80 s) came out 9–15 dB below: the speech stays.
- **Screen lock** (side button, 2026-11-25; Auto-Lock is off on this phone):
  - Sintel locked at 22 s and stayed locked for about 45 s. Scene phase went inactive → background,
    and the log carried `appState=bg`.
  - The position kept advancing in real time (31 → 62 s), with 1.7–2.2 s queued. F=512 windows ran in
    the background at 267–276 ms (thread CPU = wall time), with no hold.
  - After unlocking, the same playback was still running.
  - So the CPU and the network keep working while audio plays (PRD §4.5).
- **The player outlives its screen:** RootView owns it and stops it when the screen's route is popped,
  not in `onDisappear`, so a lock or a sheet can't stop it. Every stop logs
  `voices stop reason=stop button|left the screen|new video`. Two early "lock" runs turned out to be
  the developer stopping playback; the reason line now tells those apart.

### D44. Video, sync and seek — US-013

- **`PlayerEngine`** (the US-012 player, renamed) carries an optional `VideoInput`: the H.264 file, its
  fetcher, and a display layer's `sampleBufferRenderer` on the same synchronizer.
  - Samples stay compressed; the renderer decodes them in hardware.
  - They're pulled by `requestMediaDataWhenReady`; the renderer keeps 1–2 s queued (Mac probe and
    iPhone).
  - `VideoInput` is `@unchecked Sendable`: the SDK doesn't mark the renderer Sendable, but it exists
    to be fed off the main thread, and only the engine's queue touches it.
  - A standalone `AVSampleBufferVideoRenderer` never asks for data on the Mac; one taken from a
    layer does, on screen or not, so tests use a layer.
- **Edit lists:** YouTube's H.264 starts at PTS one frame (512/15,360 at 144p, 1001/30,000 at 30 fps)
  with an edit list of the same value, and the engine applies it, so frame 0 shows at 0. The
  cross-check: the same video's VP9 file (WebM, no reordering) has its first block at 0.00 ms.
  Android's media3 applies the same single-edit offset.
- **Hold:** starvation now counts the picture too: less than 0.25 s of displayable frames queued, while
  in the foreground and not catching up. The start and seek holds wait for both tracks.
- **Seek (PRD §4.2):**
  - Both renderers and the stage are flushed.
  - The picture restarts at the target segment's keyframe. Frames before the target get
    `kCMSampleAttachmentKey_DoNotDisplay`: decoded, not shown.
  - The first shown frame in decode order can be up to a few frames past the target (B-frames);
    the target's own frame follows it and is shown.
- **The Remove-music switch restarts only the audio.** The queued picture stays valid at the same
  clock time, so it isn't flushed or refetched.
- **Segment cache and prefetch:**
  - A per-file LRU cache (16 MB audio, 48 MB video) serves seeks back and switches without a request.
    Many segments fit, so the one being played is never the one a new write evicts.
  - Video prefetches one group: a 1080p segment (1–2.5 MB) is requested as soon as the previous one
    is handed out, not when the renderer runs short.
- **Background without PiP:**
  - `didEnterBackground` stops the video feed and fetch; the voices play on.
  - **Measured, not fed:** the renderer still fails in the background with `requiresFlushToResumeDecoding`
    and AVFoundation error -11847 (`AVErrorOperationInterrupted`). This settles the PRD §4.2
    `[verify]` item.
  - `willEnterForeground` flushes the renderer and restarts at the segment holding the playhead.
    Frames earlier than the playhead + 0.1 s are hidden while it catches up, and that catch-up doesn't
    hold the voices.
  - If the renderer fails while feeding, the video stops quietly and the next activation restarts it.
    Not a playback failure.
- **YouTube's AAC runs 38.9 ms late, undeclared, and the engine compensates** (closes D42's
  question):
  - `--sync-check` decodes a sync test ("Five minute sync test", `szoOsG9137U`, a sweep with "Bip!"
    and its waveform drawn on frame 0 of every second, 480p30).
  - On the engine's timeline, the AAC beeps land 84.5 ms after their frames (83.8–85.0, 40 pairs).
    The same audio decoded from YouTube's Opus file lands at 45.5 ms. That file's WebM header states
    its delay: `pre_skip` 312, `CodecDelay` 6.5 ms, subtracted.
  - So the AAC is 39.0 ms later than the Opus. `--delay-check` cross-correlates the two decodes on any
    video: 38.9 ms for 4 of 5 (correlation 0.987–0.997), and 33.9 ms for Sintel, an older upload.
  - None of this is declared: no `elst`, no gapless tag (D42).
  - `PlayerEngine.Configuration.audioDelay` moves the audio earlier by a given amount and drops what
    falls before 0. The app sets 38.9 ms for AAC-LC at 44.1 kHz (`YouTubeAudio`); for Sintel that's
    5 ms early, which nobody can hear.
  - After the trim, the engine's AAC beeps land at 45.6 ms: the Opus/WebM timeline to 0.1 ms.
  - The remaining 45.5 ms is in YouTube's encoding of that upload. Its Opus, VP9 and AAC all agree,
    so any correct player shows it.
  - **Differs from Android:** media3 sees no encoder delay and plays YouTube's AAC about 39 ms late.
  - Apple's Opus decoder returned 120 frames (2.5 ms) fewer than packets × 960. Whether those are held
    back or dropped is unknown, so the reference carries ±2.5 ms.
- **Renderer clocks:** each renderer's timebase stays within 0.02 ms of the synchronizer's clock
  (`audioClockMs`/`videoClockMs` on the position line), so both present on one clock. The
  synchronizer compensates audio output latency itself. A slow-motion recording of the screen and
  speaker, the PRD's last check of the output side, still needs the developer.
- **Measured on the iPhone** (home Wi-Fi, Debug build, 2026-11-25; Sintel at 1080p, 1920×818 avc1):
  - **Seeks:** median **938 ms** over 10 seeks (445–1,420), and **456 ms** (328–647) in a second run
    of the final build, against the 1.5 s target.
  - **Picture after the background:** the first frame is shown **94–163 ms** after the return
    (median 129, 3 rounds, unattended: the app opens the Files app, and `devicectl … launch` brings
    it back). The voices never stopped.
  - **Start with the picture:** tap to first voices and picture took 1.0–2.4 s. The slow case was
    the video's first request to an unproven node (881 ms).
  - Both tracks stay 1.5–2.2 s queued while playing.
- **Test harness:**
  - The debug screen is now "Watch (debug)": picture on top, an "Audio only" switch, and a
    "Preparing voices…" overlay.
  - Launch flags: `--seek-check`, `--background-test`, `--sync-check [<id>] [--sync-seconds <s>]
    [--sync-frames]` and `--delay-check [<id> …]`.

### D45. The debug watch screen — US-014 (ends PR B's code)

- **Links:** `VideoLink` (YouTubeEngine) ports SmartTube's `IntentExtractor`:
  - the id comes from `v`, else the first of `video_ids`, else a `vnd.youtube://` host, else the last
    path segment, and is accepted at 11 characters;
  - `t=` gives the start (`90`, `1m30s`, `1h2m3s`).
  - iOS also takes bare ids and links without a scheme, and checks the id alphabet; Android checks
    only the length.
  - Covered: watch, `m.`, `music.`, youtu.be, shorts, embed (and nocookie), live, `watch_videos`.
  - Refused: channel links, handles and searches.
- **Screen** ("Watch (debug)", `WatchDebug`):
  - a link field with a `PasteButton`, which reads the clipboard without the paste prompt;
  - play/pause and ±10 s;
  - a seek bar that seeks on release;
  - the H.264 quality picker (`VideoOption`: every avc1 ≤ 1080p and ≤ 60 fps, one per label, best
    first);
  - the Remove-music switch: an audio flush, the engine is kept;
  - the overlay while holding: "Preparing voices…", or "Downloading voice models… N%" while
    playback waits for the models.
- **Quality switch** (`PlayerEngine.switchVideo`): reads the new file's header, then restarts the
  picture at the playhead and catches up as after the background. The old picture stays up meanwhile
  (a flush keeps it), and the voices play on.
- **Right to left:** with forced RTL, the screen mirrors, but the seek bar and the playback buttons
  stay left to right: timelines show the tape's direction (Apple HIG, "Right to left"). Debug strings
  stay English. The real Arabic check needs US-025's localisation: iOS lays out an app without an
  Arabic localisation left to right, even with Arabic as the language.
- **Measured:**
  - Simulator: a fresh install played with no models. The overlay showed the download (0 → 100 % in
    ~3 s on the Mac's network); the start hold lasted 4.1 s, of which `waitModelMs` 2,962.
  - iPhone, `--quality-check`, Sintel from 1:40: 6 switches (128p → 818p). The picture caught up in
    102–648 ms after each, with no hold and no gap in the voices.
- **Not done here:** the PR's demo recording from the iPhone (needs the developer). The simulator's
  `simctl io recordVideo` fails without a Simulator window (SimRenderServer error 2). Screenshots
  are in the gitignored `ios/build/demo/`.

### D46. The source walk, signed out — US-015

- **The order:** `SourcePlanner` ports MediaServiceCore's `PhoneSourcePlanner` whole, including the
  recovery, wall and live-card shapes US-017 will feed. Two differences:
  - It leaves out MWEB, WEB and WEB_SAFARI, which need PO tokens (PRD §4.4).
  - The tail keeps Android's order, IOS before ANDROID_REEL. The PRD's US-015 line wrote ANDROID_REEL
    → IOS; Android is the reference, and neither has been measured to serve what the first four
    refuse.
  - Android's `PhoneSourcePlannerTest` is ported with its expected strings verbatim, the three web
    clients dropped by a helper.
- **The walk:** `SourceWalker` ports `VideoInfoService.firstPlayable` for the signed-out lane:
  - TV_TIZEN is admitted after an anonymous non-web content refusal, once, on a 7 s budget;
  - the age-gate stop;
  - terminal consensus;
  - `BotCheckWalkState` (hold, walk on, discard on a serve, a lone challenge amid refusals);
  - a repeated sign-in request is confirmed only by a second video within 10 min, and only when the
    walk's sign-in requests agree;
  - the circuit: 15 min, one probe a minute, earned only by a walk that reached the end, cleared by
    a network change;
  - the anonymous-challenge memory (15 min, web sources last);
  - the live hold (only ANDROID_VR after a live answer without DASH);
  - 45 s per walk, 1.5 s minimum per attempt, transport-down after 2 silent attempts.
- **Identities, iOS has two:** every source rides the youtube.com/tv visitor except WEB_EMBED, which
  rides its embed page's (PRD §4.4, D37). Android's VISIONOS and ANDROID_VR ride a third, the web
  session's. Consensus therefore settles on the same allowlisted terminal key from 3 sources over
  both identities (removed or members only: at request 3, Android at 4).
  - A walk with no WEB_EMBED agreement can't settle: for a removed video WEB_EMBED answered a generic
    ERROR, which is neutral, so all 5 sources were asked. Android's 3-identity rule exhausts there
    too.
- **The classified text:** answers are classified on reason and subreason joined with " • ", the text
  Android's walk reads (`VideoInfo.getPlayabilityStatus`). US-009's `AnswerKind` read the reason only.
- **Replay** (`WalkReplayTests`): Android's device fixture (`device_walks.json`, MediaServiceCore
  `902e4d17`, copied with its provenance) runs through the iOS walk.
  - Covered: 12 signed-out cases (kids, adult embeddable and not, live, removed, private + ordinary +
    members in one process, paid, music only, and the first walks of three recovery cases), 15 walks.
  - Each must ask the device's sources (minus the web three), in order, and settle the same way.
  - Two walks are named as changed by the 2-identity consensus.
  - Disabling the TV_TIZEN admission fails 5 cases, so the replay has teeth.
  - Media failures (US-017) and signed-in cases (US-022) aren't replayed yet.
- **Requests** (`PlayerSources`):
  - each source's QueryBuilder body, a total per-attempt timeout (no answer → no response);
  - ANDROID_REEL to `youtubei.googleapis.com/…/reel/reel_item_watch`, its `playerResponse` unwrapped;
  - WEB_EMBED's identity from `youtube.com/embed/<id>?html5=1` (Safari UA, reddit Referer):
    `encryptedHostFlags` with that page's own visitor, the two bound, cached 6 h, invalidated on a
    152 refusal.
- **iPhone (home Wi-Fi, 2026-11-25):**
  - "Baby Shark Dance" (`XqZsoesa55w`, made for kids) played through anonymous TV_TIZEN at request
    2. VISIONOS answered "This video is not available"; the walk took 350–381 ms.
  - The issue #5 video in the fixture (`_WB5hh7WOb4`) is now "removed by the uploader": every source
    agreed except WEB_EMBED's generic error.
- **Not ported yet:**
  - `BotWallBook` (the network wall's plan) and the recovery state (suspects, recent refusals,
    walls): US-017;
  - `KidsChannelMemory` and the live card: they need the app to name a video's channel or live
    state (Phase 4);
  - live playback: a live answer is reported as "live streams don't play yet".
  - TV_TIZEN answers carry no title in `videoDetails` (the screen shows the id); the watch page gets
    titles from `/next` (US-020).

### D47. The challenge solver: JavaScriptCore, with a warm-up — US-016

- **The bundle:** MediaServiceCore's solver bundle (yt-dlp's EJS `yt.solver.core.js`, meriyah 6.1.4,
  astring 1.9.0, its `polyfill.js`; `8e92399b`, licences in `JS/nsigsolver/README.md`) runs
  unchanged in a `JSContext`.
  - The context lives on one serial queue (`ChallengeSolver`, an actor on a `DispatchSerialQueue`).
  - The input is `jsc({type: "player"|"preprocessed", …})`, as Android's `JsRuntimeChalBaseJCP`
    sends it.
  - The preprocessed player is kept on disk per player id (Caches), the raw player JS too
    (`PlayerScripts`), and solved values in memory.
  - MediaServiceCore's `newtube.memo.js` isn't used.
  - The resource folder is `JS`: a package folder named `Resources` fails the app's code signing
    ("bundle format unrecognized").
- **What gets solved:** every `n` in the answer's URLs and every `s` in its `signatureCipher`, in one
  bulk call, with the TV player whose `signatureTimestamp` the requests sent. The signature goes in
  as `<sp>=` (default `sig`); the other parameters keep their encoding byte for byte. An answer with
  nothing to solve (VISIONOS, ANDROID_VR) isn't touched (Android's `setSkipSolveWithoutChallenges`).
- **Correctness:** JavaScriptCore gives exactly V8's answers. `ios/tools/solver_oracle.sh` downloads
  the current TV player (`b485e332`) and records Node's (V8's) answers to 6 `n` and 4 `sig`
  challenges; `ChallengeSolverTests` gets the same answers on the Mac, and the iPhone's
  `--solver-check` gives the same sample. googlevideo served the deciphered TV_TIZEN URLs (206).
- **Speed on the A15** (`--solver-check`, 3 rounds):
  - a cold solve (fresh context, the raw 2.3 MB player): **1,661–1,790 ms**;
  - from the preprocessed player: **74–84 ms**;
  - from the memo: 0 ms.
  - Mac: 1.2 s cold, 60 ms preprocessed; V8 280 ms cold.
- **Deviation from PRD §4.4** ("above 1.5 s, move it into a hidden WKWebView"):
  - The cold solve is over 1.5 s, but it happens once per player version (YouTube ships one about
    weekly), and its result persists. Every video after that costs 75–86 ms.
  - So the cold cost moves off the critical path instead: `PlaybackServices.warmUp()` preprocesses
    the current player in the background at launch.
  - A WebView would add an out-of-process round trip per solve and is suspended in the background.
  - Measured: first ciphered video cold, 1.76 s of solve and 2.9 s tap to voices. After the
    warm-up, 86 ms and **1.13 s**.

### D48. 403 recovery and the one-minute wall — US-017

- **The engine's side:**
  - A `MediaRefused` in either feed goes to the app's recovery as a `MediaRefusal`. It carries the
    track, the itag, where the refused request started on the stream, and the lowest and highest
    starts of this open's served requests. The request starts are marked by `FMP4Reader`; the opening
    segment that came with the header request counts as one at 0.
  - One recovery runs per open: the other track awaits the same walk.
  - What comes back, for each track:
    - the same file (itag, `lmt` and length) at a new URL: both fetchers repoint, and the feeds carry
      on from the refused segment; nothing is visible;
    - or a replacement file: audio restarts at the playhead (a short hold, like the Remove-music
      switch), and the picture catches up as after the background.
  - Android reloads the player in that second case.
- **The app's side** (`VideoResolver.recover`):
  - It blames the winner: the account route's record (`SourceWalker.noteMediaRefused`) and the wall
    book.
  - It re-rolls the visitor when the book asks.
  - It walks with the suspect last, in the VOD order that asks ANDROID_VR late, with walled sources
    benched and re-rolled ones refreshed; then deciphers the answer.
  - It picks the same files by itag, `lmt` and length. TV_TIZEN's answers can hold two itag-140 files
    (one with DRC), so the itag alone repointed to the wrong one and the fetcher refused it.
- **`WallBook`** ports `PlaybackWallMemory` and `notePlaybackMedia403`.
  - **Signature:**
    - `ordinary`: refused before 55 s of stream, or a served request started at 65 s or later
      (Android logs this as `none`; the PRD called it `ordinary`);
    - `wall`: a request below 60 s was served;
    - `ambiguous` otherwise. It is confirmed by a remembered pair, or by a second refusal past the
      wall on the same video.
  - **Memory:** 6 h, 32 pairs, keyed by a 10-hex-character visitor fingerprint (SHA-256), never the
    visitor itself, and persisted.
  - **Bench:** the source is benched in that video's recoveries for 30 min.
  - **Re-roll:** the first wall of VISIONOS or ANDROID_VR re-rolls the visitor, 2 per 6 h and once
    per video (persisted). `VisitorIdentity.reroll` asks youtube.com/tv without the stored identity
    cookie.
  - **Differs from Android:** iOS re-rolls its one visitor (the youtube.com/tv one, used by every app
    source); Android re-rolls the web session's visitor (VISIONOS, ANDROID_VR).
  - Log lines: `playback-media403 … signature=wall|ambiguous|ordinary`, `playback-wall … how=…`,
    `wall-swap …`.
- **The walk gained Android's recovery memory:**
  - `RecentRefusals`: sources that refused the video in the last 30 min are asked after the suspect;
    after a made-for-kids refusal, the sources that never serve kids videos go behind it.
  - The account route's record (`BotWallBook.noteRouteFailed`): a media 403 benches TV_TIZEN for that
    video for 30 min, and for the network once a second video fails. It is persisted (Android keeps
    it within a boot), so a restarted app doesn't re-admit TV_TIZEN.
- **The replay** now covers the three recovery cases.
  - The kids video's recovery from TV_TIZEN goes straight to WEB_EMBED (recent refusals).
  - The bench-and-recover case uses the made-for-kids order.
  - The walled visitor's recovery asks WEB_EMBED, then TV_TIZEN, which serves, as on the device.
  - **Not supported on iOS:** four walks where WEB_EMBED answered SABR-only with an HLS manifest. Android
    plays those over HLS; the iOS engine plays fMP4 only, and YouTube's VOD HLS is MPEG-TS. They're
    named in the test, and iOS walks on. HLS for VOD is left for later.
- **The synthetic wall** (`--synthetic-wall`, the "Synthetic wall at 1:00" switch, `--wall-check`):
  - the first answer's links refuse every request starting at or past 60 s of stream
    (`MediaFetcher.setSyntheticRefusal`), until a recovery repoints them;
  - its walls go to a separate book (`walls-synthetic.json`), and it skips the account route's
    record, so a fake wall never benches a source for real. Re-rolls are real.
- **iPhone, `--wall-check`** (4 videos from 0:50, home Wi-Fi):
  - **First run, 3 of 4:**
    - two recoveries went to TV_TIZEN (641–677 ms) and one to VISIONOS (1,068 ms);
    - one failed: ANDROID_VR had no copy of TV_TIZEN's itag-140 file. That led to the replacement
      path.
  - **After the fix, 4 of 4:** no error, no rewind; each recovery walk took 0.94–1.17 s and
    repointed the same files (re-roll budget spent, VISIONOS answering fresh links last).
  - The replacement path is covered by a package test.

### D49. The system player: Now Playing, PiP, full screen, speed — US-018

- **Now Playing** (`NowPlaying`):
  - Shows the title, channel, artwork (the largest thumbnail, fetched once), duration, elapsed time
    and rate, with media type video.
  - The system extrapolates the position from elapsed and rate. So these are published only when the
    rate or duration changes (play, pause, a hold, a speed change) or the position jumps more than
    0.5 s from the extrapolation (a seek). Over the check's first 40 s, with four speed changes, that
    was 9 publishes, and the extrapolated position was 0.09 s from the engine's.
  - **Remote commands:** play, pause, toggle, skip ±10 s and scrubbing. They call the same paths as
    the screen's buttons.
  - **The artwork handler must be nonisolated.** MediaPlayer calls it on its own queue. A closure
    written inside a `@MainActor` class is main-actor isolated, and Swift 6's runtime check traps
    (a SIGTRAP on the simulator the first time artwork was published).
- **Picture in Picture** (`PictureInPicture`): `AVPictureInPictureController` on the engine's display
  layer (`ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`), with
  `canStartPictureInPictureAutomaticallyFromInline`.
  - The background rule (D44) waits 600 ms after the app leaves for PiP's will-start. While PiP runs,
    the picture keeps decoding; if PiP closes while the app is away, the picture stops as before.
  - The delegate's play, pause, skip and time range go to the same handlers as the remote commands.
  - The simulator doesn't support PiP (`isPictureInPictureSupported` is false there), so it's checked
    on the phone only (`--system-check`).
- **Interruptions and headphones:** these come from US-012's `PlaybackAudioSession`:
  - an interruption that begins pauses playback;
  - an interruption that ends with `shouldResume` plays again;
  - `oldDeviceUnavailable` (headphones unplugged) pauses.

  A check can't make a phone call or unplug headphones, so this is the user's to try.
- **Full screen:** the same display layer moves into a full-screen cover, so nothing reopens.
  - The orientation is locked by an app delegate: portrait everywhere (US-020: portrait, plus
    landscape full screen), landscape in full screen.
  - Changing the lock and calling `setNeedsUpdateOfSupportedInterfaceOrientations` rotates the scene.
    An explicit `requestGeometryUpdate` on top of it was refused every time ("Supported: portrait"),
    because it raced the controllers' update, so the app doesn't send one.
  - The hosting view has an `active` flag. Without it, the inline view never took the layer back and
    stayed black after full screen closed.
- **The screen doesn't sleep** while a picture plays in the foreground (`isIdleTimerDisabled`). It
  can sleep again on pause, background and stop.
- **Speed** (0.5–2×):
  - It sets the synchronizer's rate, so picture and voices stay on one clock.
  - The audio renderer uses `audioTimePitchAlgorithm = .timeDomain`, which Apple describes for speech.
    Which algorithm sounds better is the user's ear test (PRD `[verify]`).
  - The pump's wait is divided by the speed. Separation runs at about 46× real time on the phone
    (BENCHMARKS), so 2× has headroom.
- **`--system-check` on the simulator: 11 of 12 pass.**
  - Speeds measured 0.500, 1.500, 2.000 and 1.000.
  - Now Playing ok; pause sets rate 0 and lets the screen sleep; skip went 41.0 → 51.8 s; scrub to
    30 s landed at 31.0 s.
  - Full screen measured 812×375 landscape, and portrait again after closing with the layer back
    inline.
  - PiP fails because the simulator doesn't support it.
- **`--system-check` on the iPhone (run after the commit; the phone was locked, then unavailable):
  12 of 12 pass.**
  - Speeds measured exactly 0.5, 1.5, 2 and 1, with no hold at 2×.
  - Now Playing within 0.08 s of the engine; skip went 41.2 → 52.6 s; scrub to 30 s landed at 31.5 s.
  - Full screen measured 812×375 landscape, then portrait with the layer back inline.
  - PiP started on its own as the app left for Files. While it ran the picture kept decoding:
    1.25–2.25 s of frames queued ahead, and the playhead moved 8.2 s in 8 s. It stopped when the app
    came back.

### D50. Search: the TV client, lockup cards, Android's list rules — US-019

- **The request** ports `SearchApi.getSearchResult` and `SearchApiHelper` (no filters yet):
  - It's the TV client (`ClientProfile.tv`: AppClient.TV, TVHTML5 `7.20260707.07.00`, the Cobalt UA,
    `POST_DATA_BROWSE_TV`).
  - It carries the app's visitor in the body and the `X-Goog-Visitor-Id` header.
  - It's retried once on a transport error or a 5xx (SearchService2 retries with a cloned call); a
    4xx is an answer.
  - It goes through `BrowseClient`, which the channel and feed pages will use too.
- **The answer (2026-11): every item is a `lockupViewModel`**, not a `tileRenderer`.
  - `FeedParser` reads lockups (video, short, channel, playlist) and `shortsLockupViewModel`. It also
    reads `tileRenderer` and the classic `*VideoRenderer`s, for the browse pages.
  - A video's channel id comes from its long-press menu's "Go to channel" (CommonHelper.kt
    `getBrowseId`).
  - The length badge sits in `thumbnailBottomOverlayViewModel.badges`. CommonHelper.kt reads only
    `thumbnailOverlayBadgeViewModel.thumbnailBadges`, so iOS reads both. This is a note for the
    Android side, not a change to it.
  - Only `shelfRenderer`s are sections, as on Android; the `clusterShelfRenderer` (a channel's
    videos) is dropped. The first shelf with a next page is the one that continues.
  - Fixtures in `Fixtures/browse` are scrubbed of the visitor, tracking fields, `params` and the
    onesie URLs, and `fixturesCarryNoAddressOrVisitor` covers them.
- **The list rules** are in `FeedList`, so every list shares them:
  - **No Shorts, ever** (ShortsFilter: there is no setting). A Short is known by its content type
    or its reel tap.
  - **Channels first:** channels among the first page's first 10 kept items move to the top
    (`hoistChannels`).
  - Each item appears once.
  - **Top-up** (`FilteredPageTopUp`): a list that dropped Shorts and keeps fewer than 10 items
    fetches its next page itself, up to 5 pages per user action.
  - **Short lists:** when the end of a short list comes into view, that's a layout pass, not the
    user, so it shares the same budget (`takeAutomatic`).
    - Without this, each page that kept one item showed a new last row and asked again. On the
      iPhone, "shorts funny" paged 18 times before this fix.
    - Now it pages 6 times: the first page has 135 items with 1 video, then 5 top-ups; 3 videos kept
      of 235 items, then it stops.
- **History is local** (PRD), in a JSON file in Application Support:
  - newest first, each query once (ignoring case), at most 50;
  - swipe to remove one, or clear them all;
  - offered as suggestions while typing (prefix match).

  Android's history rows come from YouTube's search tags (`MediaServiceSearchTagProvider`), and
  YouTube's typed suggestions (`getSearchTags`) aren't ported yet; they're not in US-019.
- **The app now has tabs:** Subscriptions (first; a sign-in note until US-022/023), Search, and You
  (the debug screens until Settings, US-024).
  - A video opens the player screen until the watch page (US-020).
  - Channels and playlists open a placeholder until US-021.
  - Cards are full width (thumbnail, length badge, title, then "channel · views · age"). Channels
    are rows with a round avatar. Every card has one VoiceOver label.
- **Thumbnails:** `AsyncImage` through `URLCache.shared`, sized at launch to 32 MB of memory and
  256 MB of disk.
- **Right-to-left:** the app declares no Arabic localization yet (US-025), so iOS runs it in English,
  left to right, even with Arabic as the language.
  - `--rtl` forces right-to-left layout for checks.
  - In the screenshots everything mirrors: avatars and history icons on the right, the length badge
    in the leading corner, the tabs reversed.
  - The Arabic check on the phone comes with US-025.
- **iPhone:**
  - `--search "big buck bunny"`: 20 results (17 videos, 3 Shorts dropped) in 939 ms over HTTP/3;
    other runs used HTTP/2 (FR-15 allows both).
  - `--search "shorts funny" --search-more`: paging as above.

### D51. The watch page — US-020

- **`/next`** goes over the TV client (WatchNextService: the browse body with `videoId`; more related
  videos through the browse continuation on `/next`).
  - The TV answer's `videoMetadataRenderer` carries the title, views (full and short), the date
    (published and relative) and the owner (avatar, subscribers, channel id), but **no
    description**.
  - The description and likes come from the `video-description-ep-identifier` engagement panel,
    as in MediaItemMetadataImpl.
  - The comments panel's first token and count are kept for US-026.
  - The related videos are the `pivot`: grid shelves of 3 `tileRenderer`s with a list-level
    continuation (30, then 33 more for Big Buck Bunny).
  - Fixtures `next_bbb*.json`.
- **The player model** (formerly the debug screen's `WatchDebug`) is now `PlayerModel` in
  `Playback/`.
  - The watch page and the debug watch screen share it; the debug checks are an extension in
    `Debug/PlayerChecks.swift`.
  - It knows which video it plays, so going back to a watch page whose video still plays doesn't
    restart it.
- **The page:** the player on top at 16:9; under it the title, "views · age", the channel row (it
  opens the channel), and the description (3 lines; a tap expands it with the date, full views and
  likes).
  - The player shows "Preparing voices…" over the frozen frame while holding.
  - A tap shows the controls, which fade after 3 s of playback: ±10 s, play/pause, the seek bar,
    full screen, and a gear menu with Remove music, quality, speed and Picture in Picture
    (Android's gear-menu row).
  - Controls and the seek bar stay left to right in Arabic (time runs that way).
- **The musicless fork's defaults** (`BuildConfig.MUSICLESS_FORK` in the Android prefs):
  - **Up next is hidden** (PlayerTweaksData `mIsSuggestionsDisabled` = true). "Show Up next" turns
    it on: on the You tab now, in Settings with US-024. The related list follows the phone's list
    rules (`FeedList`).
  - **A video that ends stays paused** (PlayerData `PLAYBACK_MODE_PAUSE`). The engine stops at the
    end; the center button becomes Replay (seek to 0 and play), and so does the lock screen's play.
- **Full screen** is the same landscape cover as US-018, on the watch page.
- **iPhone:** `--watch jNQXAC9IVRw --up-next` (19 s):
  - the walk took 271 ms and `/next` 583 ms (30 related, description, comments token);
  - first voices 1,183 ms after the tap;
  - `voices ended at=19.04`, and nothing played after it.
- New launch flags: `--watch <id>` (the watch page) and `--up-next` (Up next for that launch, not
  saved).

### D52. The channel and playlist pages — US-021

- **A channel** is `/browse` with its id over the TV client (`tvBrowseRenderer` →
  `tvSurfaceContentRenderer`).
  - The header (`channelHeaderRenderer`) gives the name, the avatar, the banner, and a subtitle line
    of handle and subscribers.
  - Every `shelfRenderer` is a section with a title (`avatarLockup` title), its tiles and its own
    continuation: Made with Blender, Videos, Shorts, playlists, live streams, Playlists, channels.
  - The Videos shelf is the uploads. It's recognized by its link to the videos tab (browse params
    that start with `EgZ2aWRlb3M`, "videos" in protobuf), not by its title, which is localized.
- **On the phone, as Android does** (MobileChannelActivity, ShortsFilter):
  - the sections are tabs (chips here), and the uploads are selected first;
  - each section pages through its own `horizontalListContinuation`;
  - Shorts are dropped, and a section they empty disappears (#63);
  - the untitled last shelf is skipped: it's the tab row (channel cards carrying each tab's
    params), and the titled shelves already are those tabs.
- **A playlist** is `/browse` with `VL<id>` (`twoColumnRenderer`: `entityMetadataRenderer` for the
  title and owner, `playlistVideoListRenderer` for the videos and their continuation).
- **One continuation reader** (`FeedParser.continuationPage`) covers `sectionListContinuation`
  (search, related) and the single-list kinds (`horizontalListContinuation`,
  `playlistVideoListContinuation`, grid, vertical).
- **The tile parser** now knows `TILE_CONTENT_TYPE_SHORTS` and the lines' badges ("4K").
- **Thumbnails** fill and crop their frame. A video whose `hq720.jpg` has baked-in pillarbox bars
  shows them, as on YouTube.
- **Fixtures:**
  - The Blender channel is trimmed to 6 items per shelf. The scrubber now keeps a browse endpoint's
    `params` (they name a tab) and drops only a watch endpoint's (the blob with the false "Cgt"
    match).
  - Also recorded: the Videos continuation and the Open Movies playlist.
- **iPhone:** the channel took 806 ms (15 sections, 199 items in an 842 KB answer; uploads found),
  the playlist 216 ms (15 videos and a continuation), both over HTTP/3.
- New launch flags: `--channel <id>` and `--playlist <id>`.

### D53. Sign-in, the signed-in lane, watch history — US-022

- **The device-code flow** ports AuthService V2 and AuthApiHelper:
  - **Client id and secret:** fetched at sign-in from the youtube.com/tv app's base script, never
    built in. The Cobalt page links it as `.src = '…m=base'` (AppInfo's second pattern), and
    ClientData's regex takes the first `clientId:"…apps.googleusercontent.com",x:"secret"`.
  - **Code:** `/o/oauth2/device/code` with the TV scope, model `ytlr::` and a per-install device id.
  - **Polling:** `/o/oauth2/token` every `interval` (5 s), plus 5 s on `slow_down`. A network error
    while the user is away in Safari is retried: the code stays valid (AuthService's note).
  - **Refresh:** access tokens are refreshed 60 s before they expire, one refresh at a time.
    `invalid_grant` signs out.
- **The sheet** follows Android's MobileSignInActivity and YTSignInPresenter:
  - the code, Copy, "Continue with Google" (the code-prefilled `youtube.com/qr/activate/<code>` in
    Safari inside the app), and yt.be/activate as the manual way;
  - the sheet and Safari close once the token arrives.

  The PRD named yt.be/activate alone; Android leads with the prefilled page, and so does iOS.
- **Secrets stay in the Keychain only:** the refresh token and the client it was minted for
  (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so a locked phone can refresh, and nothing
  syncs or backs up).
  - The account's name and photo are cached in UserDefaults for the next launch, without the
    e-mail.
  - No token, code, client id or secret is logged: the transport logs the path and status only.
- **FR-17:** the account goes only on:
  - the account route (TV_TIZEN, signed-in lane);
  - the history /player (`ClientProfile.tv`);
  - TV-shaped browse requests;
  - the stats pings (Android's interceptor sends it there too).

  `PlayerSources` drops it for any other client.
- **The signed-in lane** (planner already ported, US-015): VISIONOS first, then TV_TIZEN **with the
  account** on Android's 15 s budget (`accountRouteBudget`); recoveries too. A test pins the order
  and the budget.
- **Account row:** `accounts_list` (AccountsList/AccountInt), the selected account or the first, on
  the You tab with Sign out (after a confirmation).
- **Watch history** (LANES §3, TrackingService, VideoStateController.saveState):
  - **When:** pings go at playback start, pause, end (fully watched) and stop, at a position of at
    least 3 s.
  - **Tracking:** their `ei`, `vm` and `of` come from an answer asked with the account, with that
    request's CPN (`PlayerAnswer.requestCPN`). That's the account route's answer when it won,
    otherwise one TV 7.x `/player` with the account (`historyTracking`), up to 3 tries per video.
  - **Rules** (`WatchHistory`): a new record under 3 min starts from 0; a record renews after
    30 min; the last 5 % marks the video fully watched.
- **Checked here:** the flow up to polling, on the simulator and the iPhone (client data
  268 + 51 ms, a code with 1,800 s and a 5 s interval, polls answering `authorization_pending`).
- **The user's to check:** completing sign-in (it needs a Google account), the signed-in lane's
  TV_TIZEN with the account, the history pings' status, and whether YouTube credits them (LANES §3
  calls that the owner's check).
- New launch flag: `--sign-in` opens the sheet.

### D54. Subscriptions and Home — US-023

- **The feeds** are `/browse` over the TV client with the account (BrowseApiHelper): Subscriptions
  `FEsubscriptions`, Home `default`. They throw when signed out.
- **The parser** follows BrowseHelper.kt's `BrowseResultTV`:
  - Subscriptions is a `tvSecondaryNavRenderer` whose tabs are "All" and one per channel. The feed
    is the tab that browses `FEsubscriptions`, else the first (`getSubscriptionsTab`).
  - Home is a `tvSurfaceContentRenderer`.
  - Either one holds a `gridRenderer` or a `sectionListRenderer`. The section reader now also takes
    bare grids, item sections (the Subscriptions page's rows of 3) and grids inside shelves.
  - **Untested against a real answer:** a signed-in answer can't be recorded without an account, so
    the tests build Subscriptions and Home in that shape from recorded tiles. The recorded
    signed-out Home is a search bar only: an empty page.
- **The fork's defaults** (MobileMainApplication's first run):
  - Home is off ("YouTube's signed-out Home can't be filtered") and the app boots on Subscriptions.
  - "Show Home" (on the You tab until US-024) adds a Home tab before Subscriptions; the app still
    opens on Subscriptions.
  - Signed out, Subscriptions shows a sign-in prompt that opens the sign-in sheet.
- **The same first run also** sets the app language to Arabic and starts the voice-model download.
  The language is US-025's (iOS uses its per-app language page, PRD); the download is US-024's.
- The feeds follow the phone's list rules (`FeedList`), page through `gridContinuation` or
  `sectionListContinuation`, and refresh by pulling down. Each tab has its own navigation stack;
  the player stops when no stack shows a watch page.
- **The user's to check:** the feed itself, once signed in.

### D55. Settings — US-024

- **Reached from You**, which now holds the account and Settings (FR-18; Downloads and Open a file
  come with US-027/028). The debug screens moved into Settings' Debug section.
- **Music removal:**
  - Remove music is on by default (MusiclessPrefs). It's one setting: the player menu's switch
    changes it too, as on Android.
  - Voice models: the status, the size on disk (39.3 MB), and Download, Retry or Re-download (after
    a confirmation). `ModelStore` gained `bytesOnDisk` and `redownload()`, which deletes the
    published and partial files.
  - **The download now starts at launch while Remove music is on**, as the fork's first run does.
    This closes D25's "no auto-start yet".
- **Playback:**
  - Maximum quality: 1080p (the default and the H.264 ceiling) down to 240p, as the selector's
    short-side cap.
  - **Prefer 60 fps** (on): off, a ≤ 30 fps file of the same size wins, and 60 fps is chosen only
    when it's the only one at that size. Tested in `FormatSelector`.
  - **Background play** (on): off, leaving the app pauses unless Picture in Picture keeps it on
    screen.
  - Show Up next, Show Home.
- **Language:** a row showing the current language that opens the app's page in iOS Settings (PRD).
  The fork's first run sets Arabic; iOS leaves the choice to that page (US-025).
- **About:** the version and the five licences from `assets/musicless/`.
  - Musicless, Spleeter and ONNX Runtime are copied as `.txt`: XcodeGen didn't bundle the
    extensionless files.
  - Also the ONNX Runtime third-party notices (335 KB, shown in a text view) and NOTICE.
- **Debug:** the probe, the benchmark, the debug watch screen, the synthetic wall, the commit, and
  the log export (this launch's lines from `OSLogStore`, the app's subsystem, shared as a text
  file).
- New launch flag: `--settings`.

### D56. Arabic and right-to-left — US-025

- **The strings:** `ios/tools/import_android_strings.py` builds `Localizable.xcstrings`.
  - The keys are the app's own, listed by the compiler (`SWIFT_EMIT_LOC_STRINGS`, `.stringsdata`).
  - Each key is matched by its English text, first in the phone's files the PRD names
    (`strings_mobile.xml`, `strings_settings.xml`, plus the fork's `strings_fork.xml`), then in the
    shared `common` module's `strings.xml`. The PRD's three files alone matched 26 of 106; with the
    fork's and common's, 36.
  - The Arabic is the same key in `values-ar`, with Android's placeholders turned into the iOS
    specifiers, and the Android key is the entry's comment.
  - **The other 70 are iOS's own** (the player's accessibility labels, sign-in, settings, debug
    rows). Their Arabic is in `ios/tools/strings_ios_only_ar.json`, written to Android's wording
    (تعذّر…, سجّل الدخول, إزالة الموسيقى, نماذج الصوت, ملء الشاشة, صورة داخل صورة); comment
    "iOS only". **A native speaker should review them.**
  - `--check` fails on any key left without Arabic.
- **The app declares en and ar** (`CFBundleLocalizations`). The catalog builds into `ar.lproj`, so
  iOS runs the app in Arabic when Arabic is the system or per-app language. The fork's first run
  sets Arabic itself; iOS leaves the choice to the user (Settings' Language row, D55).
- **Right-to-left:** layouts mirror on their own (leading and trailing everywhere). Playback
  controls, the seek bar and the full-screen controls stay left to right, as time runs that way;
  the user code stays left to right too.
- **Numbers and durations follow the locale:**
  - the seek bar's times use `Duration` formatting (Arabic-Indic digits in ar_SA: ٠:٠٢ / ١٠:٣٤);
  - speeds use `formatted()`, sizes `ByteCountFormatter`;
  - views, ages and subscribers come from YouTube in the request's language (`acceptLanguage` is
    the locale's, so they arrive in Arabic);
  - length badges are YouTube's own text ("33:58").
- **Checked in Arabic on the simulator:** search (with channels), the watch page with Up next, the
  sign-in sheet and Settings, all right to left. On the iPhone: a launch in Arabic searching
  (`-AppleLanguages (ar) -AppleLocale ar_SA` after `--`, see ios/CLAUDE.md).

### D57. Comments, read-only — US-026

- **The request:** `/next` with the comments panel's token over the TV client
  (CommentsApiParams.getCommentsQuery); the first token comes from `/next` (D51).
- **The answer:** an `itemSectionContinuation` of the classic `commentThreadRenderer` →
  `commentRenderer` (not view models):
  - author, avatar, text, age, likes, reply count, a pinned badge;
  - the replies token in `detailViewEndpoint`;
  - the next page's token.

  A replies page (`/next` with that token) starts with the parent comment, which the parser drops
  by id.
- **On the watch page:** a "Comments · 5.2K" row under the description opens a sheet (medium or
  large) with the top comments and paging. A comment's "N replies" opens its replies on their own
  page, the parent on top, also paged. Writing comments is out of scope (US-026 is read-only).
- **Plurals:** the import tool now reads Android's `<plurals>`, matched by their English "other"
  form, and writes them as catalog variations. "N replies" takes Android's
  `mobile_comments_replies`, with all six Arabic forms ("٢١ ردًا" for 21).
- **Fixtures:** the comments and replies pages, trimmed, with authors, avatars and comment texts
  replaced (`@commenterN`, `Comment text N`): public, but other people's.
- **iPhone:** the comments came in 249 ms (20, with a next page) after `/next`. `--comments` opens
  the sheet once `/next` lands.

### D58. Local files with the music removed — US-027

- **Opening:** You → Open a file (the document picker, movies and audio), and "Open in" from Files
  and other apps (`CFBundleDocumentTypes`: `public.movie` and `public.audio`, Viewer, Alternate
  rank; `LSSupportsOpeningDocumentsInPlace` was already on).
  - Files are played in place, with security-scoped access held until the player stops.
  - `--file <name>` plays a file from the app's Documents (Files → On My iPhone).
- **`LocalPlayerEngine`** (MediaPipeline), next to the YouTube engine, behind a small
  `PlaybackEngine` protocol (start, play, pause, seek, Remove music, speed, video on/off, snapshot,
  close; quality stays the YouTube engine's). It publishes the same `Snapshot`, so the player
  model, the surface, Now Playing, PiP and history code drive either.
  - **Audio:** `AVAssetReader` decodes any codec the file has to interleaved Float32 at 44.1 kHz
    stereo. The same `SeparatorStage` (Android's d074c0c6: local files get music removal too) feeds
    the same renderer and synchronizer. The reader starts on a packet boundary, so the frames
    before the target are trimmed.
  - **Video:** the reader decodes too (IOSurface-backed frames), so a seek lands on its frame
    without keyframe handling. The display layer showed nothing until the frames were
    IOSurface-backed.
  - **The hold rule** is the YouTube engine's for the audio: less than 0.25 s queued while more is
    coming holds the clock, debounced 100 ms, and a restart begins in a hold.
    - **Not the YouTube engine's for the decoded picture:** a held display layer takes only a few
      decoded frames, never 0.25 s.
    - On the iPhone that deadlocked: the video looked starved, so the clock stayed held, so the
      layer never drained. The simulator's layer took more frames and hid it.
    - So the video side needs a frame at the target to start, and holds later only if frames fall
      behind the clock.
  - The local engine has no 403s, no walls and no history (a local file has no video id).
- **Package tests:** a 3 s AAC tone written with AVAssetWriter plays through the stage to its end,
  and a seek restarts the stage at the target (pass-through when Remove music is off).
- **iPhone:** a 32 s test movie (H.264 test pattern with the Sintel separation clip, copied into
  Documents with `devicectl device copy to`):
  - opened in 36 ms, first frame at 0;
  - the start hold released at 1.11 s queued;
  - played to `local ended at=30.05` (the soundtrack's end) with no underrun.
- On the simulator the picture and "Preparing voices…" show over the test pattern.

### D59. Download with music removed — US-028

- **Starting one:** the watch page's "Download" button ("Download without music" when Remove
  music is on) shows the player's quality list, or "Best" before the player has one. Downloads
  run one at a time and are listed in You → Downloads (progress, swipe to cancel, retry or
  delete). The list is saved in Application Support. A download the app was closed during is
  marked "Interrupted. Try again." at the next launch.
  - `--download` (with `--watch <id>`) downloads that video at "Best" once its details are in;
    `--downloads` opens the list.
- **Fetching: the media fetcher, not a background `URLSession`** (the PRD's wording).
  - Each file is read in 4 MB ranges through playback's `MediaFetcher`, so the `Range:` header
    and the 403 recovery are the tested ones, unchanged.
  - A 403 gets playback's recovery, `VideoResolver.recover`. The refusal goes to the wall rule
    in stream time (byte offsets mapped through the file's sidx, read from the bytes already
    written), the refusing source is blamed and asked last, and the new answer's copy of the
    same file (itag, lmt, length) takes over at the same offset. When there is no copy, the
    answer's replacement starts over. When the audio's recovery also answers for the picture,
    the video starts from that link. At most 3 recoveries per file; the refused URL is never
    asked again.
    - The first version resolved the video as if it were new. That never told the walker which
      source refused, so it could hand back that source's link again.
  - `--synthetic-wall` works for downloads too (the first answer's links refuse from 60 s of
    stream). googlevideo refuses by a request's start, so with the switch on a range ends at the
    wall's byte.
    - Simulator, dQw4w9WgXcQ at 1080p: `download media403 track=video itag=137
      forbiddenMs=61880`, then `signature=wall`, `wall-swap from=VISIONOS to=TV_TIZEN
      video=same:137`, `download resumed … at=24633252`.
    - The file came out as 213.04 s of audio and 213.08 s of video, and decodes without errors
      across the repoint.
    - The audio file (3.4 MB) arrived in one range, before the wall was armed, so the "picture
      answered by the audio's recovery" step hasn't run yet.
  - Leaving the app is covered by the iOS 26 background task below, not by background
    transfers. A background session would need a second, delegate-based fetch path with its own
    403 handling, and it can't run the separation anyway.
- **Remove music:** `OfflineSeparator` decodes the audio with `AVAssetReader` (Float32, 44.1 kHz
  stereo), runs it through the same `Separator`, and writes AAC-LC 128 kb/s with `AVAssetWriter`.
  An `AVAssetExportSession` passthrough then muxes it with the picture into one MP4 in Documents
  (Files → On My iPhone → NewTube Musicless; `UIFileSharingEnabled` and
  `LSSupportsOpeningDocumentsInPlace` were already on).
  - **The failure rule:** a silence window from the separator (a failed window) cancels the
    writer and fails the download with "Couldn't remove the music". No file is written.
  - The item is marked `voicesOnly`. Playing it opens the local-file screen with Remove music
    off (pass-through) and "Saved without music" in place of the switch.
- **The model gate (Android's rule):** player and download share the one `ModelRuntime` through
  `ModelGate`. A player window goes straight in; a download window waits until no player window
  is in flight.
  - iPhone, with "Me at the zoo" playing on the watch page while it downloaded: the download's
    windows queued 308–693 ms (simulator, nothing playing: 35–123 ms).
- **iOS 26:** each download is a `BGContinuedProcessingTask` (`processing` background mode;
  permitted identifier `$(PRODUCT_BUNDLE_IDENTIFIER).download.*`; registered per download with
  strategy `.queue`). Progress goes to the system UI: fetching is 0–60 %, removing the music
  60–95 %, saving the rest. When the task expires, the download is cancelled.
  - iPhone (iOS 26): `background-task submitted registered=true`, then `background-task running`.
  - The simulator refuses it (`BGTaskSchedulerErrorDomain` code 1), and the download runs in the
    foreground. Before iOS 26 it also runs in the foreground; the keep-alive fallback is US-029.
- **AVFoundation reads YouTube's fragmented video files at twice their length.** The track range
  runs on with the last frame held:
  - "Me at the zoo": ffprobe 18.93 s, `AVAssetTrack.timeRange` 37.87 s;
  - Big Buck Bunny: 634.57 s → 1269.13 s;
  - dQw4w9WgXcQ: 213.04 s → 426.08 s.
  - The samples themselves are right: the last one is at 18.867 s and lasts 0.067 s. A
    passthrough export copied the frozen tail into the file (37.9 s of picture under 19 s of
    sound).
  - So `Muxer.mediaRange` ends each track at its last sample: the latest presentation end
    among the last 32 samples in decode order (B-frames reorder). Output: 19.00 s of picture.
  - The AAC files (itag 140) read correctly, and so does the separator's output.
- **Checked:**
  - simulator: 19.02 s of AAC-LC and 19.00 s of H.264 in one MP4, voices at a mean of
    -28.9 dB and a peak of -9.6 dB;
  - iPhone: the same file, copied off with `devicectl device copy from`: same durations and
    levels, voices in 1.7 s;
  - the Remove-music-off mux, on the Mac: 19.06 s and 19.00 s.
  - iPhone (iOS 26), Big Buck Bunny (10 min), checked by the developer:
    - the app went to the Home Screen right after the download started;
    - the system progress showed while away;
    - the download finished in the background, and the file is listed in You → Downloads and in
      Files → On My iPhone → NewTube Musicless.
  - Screens checked on the iPhone in English and Arabic: the watch page's button and quality
    list, the Downloads rows, swipe actions and playback. No issues.

### D60. The remaining stories are deferred (developer's decision)

After US-028 the app is complete enough for now. These stories are **not done** and wait for a
later round: US-029 (keep-alive fallback, optional), US-030 (URL scheme and App Intents),
US-031 (share extension), US-032 (Safari Web Extension), US-033 (Live Activity for downloads,
optional), US-034 (VP9 above 1080p, optional) and US-035 (CI, optional). Start with US-030 when
work resumes: US-031 and US-032 open videos through its `musicless://` link.

### D61. Videos with several audio tracks play the original — fix to US-009

- **The bug:** nphNzcHmowk (an Arabic nasheed) played YouTube's English AI dub with the music
  removed.
  - Its answer has two AAC tracks: `ar.4` (the original, default) and `en-US.10` (the dub).
    They share itag 140 and the same bitrate.
  - `FormatSelector.audio` took the highest bitrate and never looked at the track, so a dub
    won as readily as the original.
- **Now (Android's rule, `Media3TrackAdapter.applyOriginalAudioDefault`):**
  - Each format's `audioTrack` is parsed (`id`, `audioIsDefault`, `isAutoDubbed`).
  - When a video has more than one track, the selection keeps only the original's files, then
    applies the usual rule (AAC-LC at 44.1 kHz, highest bitrate).
  - Original (MediaServiceCore `YouTubeHelper.getSabrLanguage`): the id's kind is 4, or the
    track is the default when the id has no kind. An auto-dub is never the original.
  - When no track is marked original, or there's only one track, nothing changes.
  - Playback, recovery's replacements, downloads and the debug Opus pick all go through it.
- The resolver logs `audio-track video=… chosen=ar.4 original=y tracks=ar.4,en-US.10` when
  there is more than one track.
- Checked on the iPhone by the developer: nphNzcHmowk now plays the Arabic voice.
- **Not ported yet:** Android's Audio track sheet, for choosing a dub by hand. Every video plays
  its original.

### D62. Watch history that YouTube records, the red bar, History, Watch later

- **The bug: nothing reached YouTube's history.** The pings need tracking from an answer asked
  with the account, and `historyTracking` asked Android's TV 7.x `/player` (LANES §3).
  - Signed in, that client now answers UNPLAYABLE, "The page needs to be reloaded" (in the
    account's language), with no `playbackTracking`. So `tracking=missing`, and no ping was ever
    sent.
  - `--history-probe <id>` (read only) compared the variants on the iPhone:
    - TV 7.x: UNPLAYABLE, tracking missing;
    - TV 7.x without the visitor: the same;
    - TV_TIZEN, the account route: OK, tracking complete.
  - **Now the account route goes first and TV 7.x is the fallback.** This deviates from Android,
    whose TV 7.x request is likely refused the same way (not checked there).
  - iPhone: `history-tracking client=TV_TIZEN status=OK tracking=complete`, then
    `/api/stats/playback` and `/api/stats/watchtime` answered 204.
- **The red bar** (Android: `percentWatched` on the card, VideoCardAdapter.bindProgress, filled
  from VideoStateService where the card has none):
  - `FeedItem.percentWatched` reads YouTube's value from a tile's or classic renderer's
    `thumbnailOverlayResumePlaybackRenderer.percentDurationWatched` and a lockup's
    `thumbnailOverlayProgressBarViewModel.startPercent` (CommonHelper.kt).
  - Signed in on the iPhone (`--account-lists-check`, read only): History 13/13 cards with a
    value, Watch later 9/15, Subscriptions 1/45.
  - `WatchProgress` (Application Support, the latest 1,000 videos) is this app's own record,
    signed in or out. It is written every 15 s of playing and on pause, end and stop, but not at
    the start, which is always 0 because iOS doesn't resume yet.
  - **Which value a card shows:** this app's record first, else YouTube's. Android prefers the
    card's value unless it is missing or 100; here the local record is the newest thing done on
    this phone.
  - A video closed at once shows 1 %, and the last 5 % count as watched (100), as on Android.
  - The bar is 3 pt along the thumbnail's bottom edge, filling from the leading side (it mirrors
    in Arabic). VoiceOver reads "Watched N%".
- **History tab** (Android's bottom nav has History): `/browse` `FEhistory` over the TV client
  with the account (BrowseService2 `getHistory`), the Subscriptions screen with its own wording.
  It reloads each time the tab comes back.
  - Tabs: [Home], Subscriptions, History, Search, You.
- **Watch later** (Android: You → Playlists, and "Add to Watch later" in the card menu, on by
  default):
  - **You → Watch later** (signed in) opens the playlist page for `VLWL`. The You stack now
    carries list routes (`Route.browse`), so its videos open on the watch page there.
  - **Saving:** `browse/edit_playlist` on `WL` with `ACTION_ADD_VIDEO` or
    `ACTION_REMOVE_VIDEO_BY_VIDEO_ID` over the TV client (PlaylistApiHelper), success when
    `status` is `STATUS_SUCCEEDED`.
  - Saving appears in two places: the watch page's "Watch later" button (shows "Saved", and a
    tap removes it) and a long-press menu on every video card.
  - `WatchLater` remembers what was saved, or seen in the list, during the session, so both
    places agree. A video removed from the Watch later list leaves it at once.
  - The PRD lists playlist editing as a non-goal. Saving to and removing from Watch later is the
    developer's request; other playlists stay out of scope.
- **Checked on the iPhone by the developer, signed in:** watched videos appear in YouTube's
  history in the browser, the red bars show, the History tab lists the history, and saving to
  and removing from Watch later work (the button, the card menu and You → Watch later).
- **Not done:** resuming playback where the bar says (Android does); a History entry's own menu
  (remove from history).

### D63. Resume where the viewer left a video

- **`ResumeRule`** (YouTubeEngine, with tests) ports Android's VideoStateController:
  `restorePosition`, `isStateOutdated`, the reset in `resetPositionIfNeeded`, and Video's
  `getPositionFromPercentWatched`.
  - **Normally:** this phone's record (`WatchProgress`, D62).
  - **YouTube's value instead** (signed in, from the card's red bar) when this phone has no
    record, or when its record is older than the card and more than 3 points away. Only for
    videos over 6 minutes, and only above 10 % and below 100 %.
  - **From 0:** videos up to 6 minutes (Android's "remember the position of short videos" is off
    by default, and iOS has no such setting yet), videos with less than 3 s left, and videos
    with no record.
- **When:** the watch page (and its Try again) asks the player to resume, using the answer's
  `lengthSeconds`. A link's own `t=` and the debug screens still start where they say.
- Cards note YouTube's value when they appear, keeping the first time a value was seen. The bar
  uses the same rule, so it shows where the video will resume.
- Log: `voices resume video=… at=… source=local|youtube|none [reset=short|ended] len=…`.
  Simulator: Big Buck Bunny reopened at 15 s (`source=local`), first audio at 15.36 s.
- Checked on the iPhone by the developer: a long video continues where it was left, a short one
  starts over, and a long video half-watched on another device opens near that point.

## Settled `[verify]` items

| PRD item | Result | Evidence |
|---|---|---|
| §9: Xcode 26.4 vs iOS 26.6.2 on the device | **Works.** No Xcode update needed | `xcodebuild` built for the pinned phone, `devicectl` installed and launched it, the console showed the app's log (2026-11-25) |
| §0.3 row 9: engine paths "after the submodule init" | Present, with corrections: `QueryBuilder` and `AppClient` are Kotlin, at `youtubeapi/…/common/helpers/QueryBuilder.kt` and `AppClient.kt`; `app/` has `AppService*` (visitor) and `PoTokenGate.kt`; `videoinfo/V2/VideoInfoService.java` and `videoinfo/V2/sources/PhoneSourcePlanner.java` as stated. The search, browse, next and sign-in services are located when their stories start | `ls`/`find` in `MediaServiceCore/youtubeapi/src/main/java/com/liskovsoft/youtubeapi` |
| §4.4: where the EJS solver bundle lives | `MediaServiceCore/youtubeapi/src/main/assets/nsigsolver/`: `yt.solver.core.js`, `meriyah-6.1.4.min.js`, `astring-1.9.0.min.js`, `polyfill.js`, `newtube.memo.js`; run by `app/nsigsolver/impl/V8ChallengeProvider.kt` | `find` |
| §4.6: the background GPU resource on the A15 | **Not available**: `BGTaskScheduler.supportedResources` = 0. The `continued-processing.gpu` entitlement buys nothing on this phone; background separation stays CPU + Neural Engine (§4.5 already plans `.cpuAndNeuralEngine`). Measured without the entitlement and the `processing` mode; recheck once in Phase 5 | `DEVICE-PROBE.md` |
| §0.3 row 10: string counts | Confirmed: `strings_mobile.xml` 373 en / 356 ar (plus 1 plural each). `strings_settings.xml`, which the PRD didn't count: 257 en / 255 ar | `grep -c '<string '` |
| §4.3 / US-005: the ONNX Runtime Swift package URL and version | **False.** The repo and its binary host are gone (D27). Developer chose Microsoft's NuGet package, 1.32.0 | `gh api`, `git ls-remote`, curl TLS failure on `download.onnxruntime.ai`, nuget.org catalog (2026-11-25) |
| US-003: tolerances achievable with Float32 vDSP | Yes, by ~4 orders of magnitude (D23) | `DspGoldenTests` |
| US-005: SNR threshold 35 dB | Met: 124.3 dB (Mac), 123.3 dB (simulator) (D32) | `SeparationEndToEndTests` |
| §4.3: "a few milliseconds with vDSP; the models dominate" | Yes: 12 ms of DSP in a 258 ms F=512 window on the A15 | `BENCHMARKS.md` |
| §4.5: the GPU is unavailable in the background | Confirmed: CoreML `ALL` fails every locked inference (error -6) | `BENCHMARKS.md` |
| §4.5: whether the Neural Engine keeps serving a locked-screen app | **Still open.** The `CPUAndNeuralEngine` sessions run locked at foreground speed, but probably on the CPU (thread CPU = wall time), so this says nothing about the Neural Engine. Irrelevant while ORT CPU is the backend | `BENCHMARKS.md` |
| §4.2: a display layer fed in the background fails "with an interruption error" | **True, even unfed:** the video renderer turns `requiresFlushToResumeDecoding`, status failed, AVFoundation -11847 (`AVErrorOperationInterrupted`); a flush on return resets it (D44) | `--background-test` on the iPhone |
| §4.2: AAC priming is signalled by an edit list, to be trimmed | **False** (D42); YouTube's AAC runs 38.9 ms later than its Opus, undeclared; the engine trims a fixed 38.9 ms (D44) | `--sync-check`, `--delay-check` |
| §4.4: the JS solver's speed in JavaScriptCore on the A15 | Cold 1.66–1.79 s (over 1.5 s), preprocessed 74–84 ms; kept in JavaScriptCore with a launch warm-up instead of a WKWebView (D47) | `--solver-check` |
| US-015: Android's walk replay tests' names | `VideoInfoReplayTest` (fixture `walk_replay/device_walks.json`), `PhoneSourcePlannerTest`, `BotCheckWalkStateTest` in MediaServiceCore's `videoinfo/V2` tests | `find` |
| §4.3: Spleeter's U-Net is Neural-Engine-friendly | Not established, for the same reason; would need a static-shape Core ML model (US-007's route) | — |
