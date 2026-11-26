# PRD: NewTube Musicless for iPhone

**Status:** plan only; nothing is built yet. Written 2026-11-25 from a clone of
`yshalsager/newtube-musicless` (branch `musicless` at `d074c0c6`) as the handoff for a new
Claude Code session in a fork of that repo.

**Evidence tags used below:**
- **[checked]**: verified on 2026-11-25 on the developer's Mac and iPhone, or in the iOS 26.4 SDK headers.
- **[repo]**: taken from this repo's code or docs.
- **[verify]**: an informed claim the new session must confirm before building on it.

---

## 0. Start here

### 0.1 For the developer, before the new session

1. Fork `yshalsager/newtube-musicless` on GitHub, clone the fork over HTTPS, and check out
   `musicless`.
2. Run `git submodule update --init --recursive`. `MediaServiceCore` and `SharedModules` hold the
   YouTube engine whose requests and parsers the iOS app ports. They were empty in the clone this PRD
   was written in.
3. Run `git switch -c ios/poc`.
4. Copy this file into the fork as `docs/ios/PRD.md` and commit it as the branch's first commit.
5. Open an issue on `yshalsager/newtube-musicless` saying an iOS app is coming under `ios/`, and ask
   whether PRs into `musicless` are welcome (§12).
6. Plug in the iPhone and keep Developer Mode on. Then start Claude Code in the fork and paste §0.2.

### 0.2 First prompt for the new session

```
Read docs/ios/PRD.md completely, then the files in its §0.3 reading list.
We are building the iOS app it describes, under ios/, on branch ios/poc.
Start with Phase 0 (US-001, US-002). Follow the decisions in §3, and record every new
decision, with its evidence, in docs/ios/DECISIONS.md. Don't change Android code.
Pin the iPhone's device id in every devicectl/xcodebuild command.
Stop and ask me before deviating from §3, or when a [verify] item turns out false.
```

### 0.3 Reading list (in order)

| # | File | Why |
|---|---|---|
| 1 | this PRD | the plan |
| 2 | `docs/musicless/HANDOFF.md` | how music removal works, the models, the fork's defaults |
| 3 | `smarttubetv/src/stmobile/java/com/newtube/mobile/player/Musicless*.java` (9 files, ~1,200 lines) | the code to port; §4.3 condenses it |
| 4 | `smarttubetv/src/test/java/com/newtube/mobile/player/Musicless*Test.java` | the behaviours the port must keep |
| 5 | `tools/musicless/reference.py`, `DspBenchmark.java`, `prepare_models.py` | offline reference, benchmark, model export |
| 6 | `docs/player-sources/LANES.md` §1–2.4 and §5 | which YouTube clients to ask, in what order, and why |
| 7 | `docs/player-sources/inventory-engine.md` §1 | each client's identity, request body, visitor and timeout |
| 8 | `docs/mobile-port/HANDOFF.md` §3, §8, §26–28, §34 | network facts, PO tokens, SABR, the one-minute wall |
| 9 | `MediaServiceCore/youtubeapi/src/main/java/com/liskovsoft/youtubeapi/`: `app/` (visitor, PO token), `videoinfo/V2/` (`VideoInfoService`, `sources/PhoneSourcePlanner`), `QueryBuilder`, `AppClient`, plus the search, browse, next and sign-in services [verify exact paths after the submodule init] | the request shapes and parsers to port |
| 10 | `smarttubetv/src/stmobile/res/values{,-ar}/strings_mobile.xml`, `strings_settings.xml` | the English and Arabic strings (373 and 356 entries) |

### 0.4 Rules for the iOS work

**Carried over from the root `CLAUDE.md`; still true on iOS:**
- **A googlevideo 403 is routine.** Recover by asking the next client for the same itags (§4.4).
  Never retry the same URL.
- **Byte ranges go in a `Range:` header,** never a `&range=` query parameter. See the
  416/cache-poisoning post-mortem in `docs/mobile-port/HANDOFF.md`.
- **Single-slot caches evict themselves.** Walk the eviction timeline before adding "remember one
  thing" logic.
- **InnerTube must run over HTTP/2.** URLSession negotiates it on its own, but log
  `URLSessionTaskMetrics` → `networkProtocolName` on every API request (the iOS counterpart of
  NetPath's `protocol=h2`) and check it.
- **Never edit `VIDEO_INFO_TYPE_LIST`** or other Android engine code. The iOS app ports logic; it
  doesn't change the source.

**New for iOS:**
- **Always pin the device:** `--device <id>` for `devicectl`, `-destination 'platform=iOS,id=<udid>'`
  for `xcodebuild`. This is the counterpart of the `adb -s` rule.
- **Never commit device names, UDIDs, Team IDs, OAuth tokens or visitor ids.** They live in
  `ios/Config/Local.xcconfig` (gitignored) or nowhere. Logs truncate visitor ids to 10 characters,
  as Android does.
- **Separation speed is only measured on the iPhone.** The simulator runs on the Mac's CPU and
  proves nothing about it.
- **Keep the Android log formats** (`Window pipeline …`, `hold reason=…`) so the same tools can read
  both platforms' logs.
- **The Android app is the reference.** When iOS behaves differently on purpose, say so in
  `docs/ios/DECISIONS.md`.

---

## 1. Introduction

NewTube Musicless is an Android YouTube client: NewTube's phone UI on SmartTube's engine. It removes
music on the device: a Spleeter voice-separation model runs on the audio while the video plays, so
the user hears only voices. Downloads can be saved with the music already removed.

This PRD describes the same app for the iPhone, built natively in Swift and SwiftUI and kept in the
same repository under `ios/`. It won't ship on the App Store: anyone who wants it builds it with
Xcode and their own Apple ID. That frees the design from App Review. It may use any public iOS API,
plus any capability a paid developer account can sign, including behaviour App Review rejects
(§4.6).

None of the Android code runs on iOS. What carries over:
- the models (same files and hashes), and the algorithm (§4.3);
- the measured knowledge of which YouTube clients serve what, and how to recover when one fails
  (§4.4);
- the strings, including Arabic, and the product behaviour.

## 2. Goals

- **G1. Music removal while watching.** Play any ordinary YouTube video on an iPhone 13 mini with
  only the voices audible, in sync with the video.
- **G2. Fast start.** The first voices play within 2.5 s of tapping a video on Wi-Fi (median).
  After the start, playback doesn't stall on separation.
- **G3. Background play.** Audio keeps playing with the screen locked or the app in the background,
  and the video continues in Picture in Picture.
- **G4. Everyday YouTube.** Search, watch page, channel, sign in, Subscriptions and Home, in English
  and Arabic, right to left.
- **G5. Files.** Open local video and audio files through the same pipeline, and download videos
  with the music removed, visible in the Files app.
- **G6. System integration.** Open YouTube links in the app from Safari, the share sheet and
  Shortcuts.
- **G7. Self-build.** A clean clone, the README, and a free or paid Apple ID get the app onto a phone
  in under 20 minutes, not counting the Xcode download.

## 3. Decisions already made

| # | Decision | Source |
|---|---|---|
| D1 | No App Store, TestFlight or AltStore. Builders build it themselves. | developer |
| D2 | Test device: iPhone 13 mini on iOS 26.6.2, with a paid developer account. | developer, [checked] |
| D3 | Lives in this repo under `ios/`. PRs go from the developer's fork to `yshalsager/newtube-musicless`, base `musicless`. | developer |
| D4 | **Use what the OS allows, not what App Review allows.** Public APIs and any capability a paid account can sign, including App-Review-hostile ones: background keep-alive audio, opening the app from an extension, a Safari extension that redirects YouTube. Private API only behind a runtime check and a setting, never on the main path. | developer: "think at the OS level, even for more aggressive permissions" |
| D5 | Native Swift 6 and SwiftUI, with local Swift packages testable on macOS. No cross-platform framework. | §4.1 |
| D6 | **Own the media pipeline:** fMP4 demuxer → `AVSampleBufferDisplayLayer` and `AVSampleBufferAudioRenderer` on one `AVSampleBufferRenderSynchronizer`. Not AVPlayer. | §4.2 |
| D7 | Start with ONNX Runtime and the same two ONNX models. Move to native Core ML only if the US-006 benchmark says so. | §4.3 |
| D8 | VISIONOS is the first YouTube client, as on Android: no signature cipher, no PO token, no ads. | [repo] LANES §2.1 |
| D9 | iOS 17.0 minimum; iOS 26 features (`BGContinuedProcessingTask`, the VP9 decoder registration) behind `#available`. | §4.6, open question Q7 |
| D10 | The Xcode project is generated from `ios/project.yml` with XcodeGen; the generated `.xcodeproj` is gitignored. | open question Q4 |

---

## 4. Architecture (technical considerations)

### 4.1 What carries over from Android

| Android | iOS | Carries over |
|---|---|---|
| ~200 Java files of phone UI | SwiftUI screens | design and behaviour only |
| SmartTube engine, `MediaServiceCore` (Java: RxJava, Retrofit, OkHttp) | `YouTubeEngine` Swift package | request shapes, client table, lane order, recovery rules (ported by reading) |
| media3 / ExoPlayer, Cronet | `MediaPipeline` package: URLSession, own fMP4 demuxer, AVFoundation renderers | the design of the Musicless audio sink |
| `Musicless*.java` + ONNX Runtime Android | `MusiclessCore` package: Accelerate (vDSP) + ONNX Runtime iOS or Core ML | algorithm, constants, models and hashes (§4.3) |
| J2V8 (V8) running yt-dlp's EJS solver | JavaScriptCore, or a hidden WKWebView | the same solver JS |
| `values{,-ar}/strings_*.xml` | `Localizable.xcstrings` | the strings, converted by a script (US-025) |

Kotlin Multiplatform can't take Java sources. J2ObjC and GraalVM can't carry RxJava, Retrofit and
OkHttp. So the port is a rewrite, guided by the Java code and its tests.

### 4.2 Playback: own the pipeline (D6)

**Why not AVPlayer.** Separation needs whole windows of audio ahead of the playhead: 1.5 s for the
first window, then up to 11.9 s. AVPlayer's only audio hook, `MTAudioProcessingTap` on an
`AVAudioMix`:
- runs in real time inside the render callback, with no look-ahead;
- isn't applied to HLS, the format YouTube serves Apple clients by default;
- can't stop the clock while voices are prepared.

Android solved the same problem by owning the audio sink (`MusiclessAudioSink`). On iOS, owning the
pipeline is the equivalent.

**The pipeline**

```
             ┌─────────────────── YouTubeEngine ───────────────────┐
 link/ID ──▶ │ visitor → planner walk → /player → format pair       │──▶ avc1 video URL + mp4a audio URL
             └──────────────────────────────────────────────────────┘          (+ initRange, indexRange, clen)
                         │                                      │
                 MediaFetcher (Range header, h2/h3)      MediaFetcher
                         │ video bytes                          │ audio bytes
                 FMP4Demuxer (moov, sidx, moof/trun)     FMP4Demuxer
                         │ compressed H.264 samples             │ AAC packets
                         │                               AVAudioConverter → Float32, 44.1 kHz, stereo
                         │                                      │ (priming trimmed)
                         │                               Separator (DSP + 2 models, ≤ 2 windows ahead)
                         │                                      │ voices as LPCM CMSampleBuffers
     AVSampleBufferDisplayLayer ◀── AVSampleBufferRenderSynchronizer ──▶ AVSampleBufferAudioRenderer
     (hardware decode, PiP source)    (one clock; rate 0 = "hold")        (AirPlay audio, speed control)
```

- **One clock for both tracks.** The synchronizer owns the timebase. A "hold" (voices not ready) is
  `setRate(0)`: video and audio both freeze, so the clock can't run ahead, as Android's
  `MusiclessHold` keeps it from doing. The UI shows "Preparing voices…".
- **Video** stays compressed: H.264 samples go to the display layer, which decodes them in hardware.
  Use `sampleBufferRenderer` (`AVSampleBufferVideoRenderer`, iOS 17+) [checked in SDK].
- **PiP** uses `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`
  [checked in SDK].
- **Background without PiP:** stop fetching and enqueuing video, and keep the audio. On return to the
  foreground, flush the video renderer and resume from the keyframe before the current time. Frames
  before the current time are marked `kCMSampleAttachmentKey_DoNotDisplay`. A display layer fed in
  the background fails with an interruption error [verify the exact error], so don't feed it there.
- **Seek:** flush both renderers and bump the separator's generation counter. Fetch the sidx segment
  that holds the target. Video restarts at the previous keyframe with DoNotDisplay frames up to the
  target; audio restarts the window ramp at the target. Hold until the first voices are ready.
- **Formats:**
  - Video is H.264 `video/mp4; codecs="avc1…"`, up to 1080p60 (the phone's screen is 1080 px wide).
    YouTube serves H.264 up to 1080p; above that only VP9 and AV1 (US-034).
  - Audio is AAC-LC `audio/mp4; codecs="mp4a.40.2"`, usually itag 140 at 44.1 kHz. That matches the
    model's rate, so the main path needs no resampling.
  - Choose by mimeType, height and fps, not by hard-coded itags.
- **YouTube's adaptive files are fragmented MP4.** The /player answer gives each format's
  `initRange` (ftyp + moov) and `indexRange` (sidx). Fetch those two ranges first, then whole
  segments at the sidx offsets [repo: Android builds its DASH manifest from the same fields; verify
  on fixtures].
- **AAC priming:** decoded AAC starts with encoder priming, usually 2112 samples (≈ 48 ms at
  44.1 kHz), signalled by an edit list (`elst`). Trim it, or the voices run 48 ms late. Android's
  sink carries `encoderDelay` and `encoderPadding` for the same reason.

**Alternatives considered**

| Option | Verdict | Why |
|---|---|---|
| AVPlayer + `MTAudioProcessingTap` | rejected | real time only, no look-ahead, not applied to HLS, can't hold the clock |
| AVPlayer (muted video) + AVAudioEngine (voices), synced by host time | plan B | the video path is simpler (AVPlayer plays the mp4 URL), but there are two clocks, so hold, seek, speed and drift must all be coordinated by hand |
| VLCKit / MPVKit / KSPlayer (FFmpeg) | rejected for now | they own the audio output, so a look-ahead stage means patching them; LGPL/GPL; large binaries. Revisit only for AV1 software decoding |
| FFmpeg libavformat for demuxing only | fallback | only if our own demuxer becomes a sink. YouTube's fMP4 is a narrow, regular subset (≈ 500–800 lines) |
| **Own fMP4 demuxer + AVSampleBuffer renderers + synchronizer** | **chosen** | one clock, hardware H.264, PiP, hold = rate 0; the same shape as Android's sink |

**Where each Android class goes**

| Android | iOS |
|---|---|
| `MusiclessAudioSink` (feeds the processor outside the media3 loop, holds, writes voices) | `AudioRendererFeeder` + `HoldController` (MediaPipeline) |
| `MusiclessAudioProcessor` (windows, ramp, ≤ 2 outstanding, crossfade, generations) | `Separator` (MusiclessCore) |
| `MusiclessDsp` | `Dsp` (MusiclessCore, vDSP) |
| `MusiclessModelHolder` (one thread, idle release) | `ModelRuntime` actor on one serial executor |
| `MusiclessModels` (download, resume, SHA-256) | `ModelStore` |
| `MusiclessHold` (UI notifications) | `@Observable HoldState` |
| `MusiclessFile` (offline separation of a download) | `OfflineSeparator` (AVAssetReader → Separator → AVAssetWriter) |
| `MusiclessDownloadGate` (playback paused while the model downloads) | the player waits on `ModelStore.ready` |

### 4.3 Music removal: exact port spec [repo]

Condensed from `MusiclessDsp.java`, `MusiclessAudioProcessor.java` and `MusiclessModelHolder.java`.
The Java code is the authority when this summary and the code disagree.

```
Constants: RATE = 44100, FFT = 4096, HOP = 1024, BINS = 1024, MAX_FRAMES = 512, OVERLAP = 2*HOP = 2048
A window of F frames holds F*HOP samples per channel, with F ∈ {64, 128, 256, 512}.

analyze(block: F*HOP stereo samples, interleaved):
  rms  = sqrt(mean(sample²)) over both channels
  gain = clamp(10^-1.2 / (rms + 1e-9), 10^-1.5, 10^1.5)   // the model sees a -24 dBFS RMS window, at most 30 dB gain
  hann[i] = 0.5 - 0.5*cos(2πi/FFT)                         // periodic Hann
  for c in 0...1, f in 0...F                               // F+1 frames
     n    = f*HOP - FFT/2 + i                              // centred frames
     n    = n < 0 ? -n : n >= W ? 2*(W-1) - n : n          // reflect padding, W = F*HOP
     X    = FFT(block[n][c] * hann[i])                     // forward, unnormalised
     spec[c][f][k] = X[k], for k < BINS                    // complex, kept for synthesis
     if f < F: mag[c][f][k] = |X[k]| * gain                // model input (the last frame isn't used)
  model input: float32 tensor [2, 1, F, 1024], laid out (channel, split, frame, bin)

infer:  v = vocals(mag);  a = accompaniment(mag)           // same input, same output shape
        mask = (v + 5e-11) / (v + 2a + 1e-10)              // element-wise

synthesize:
  for c, f in 0...F
     Y[k] = spec[c][f][k] * mask[c][min(f, F-1)][k] for k < BINS; 0 for BINS ≤ k ≤ FFT/2   // ~11 kHz low-pass, as on Android
     Hermitian mirror; y = IFFT(Y) / FFT
     out[f*HOP - FFT/2 + i][c] += y[i] * hann[i]           // only indices inside the window
  out[n][c] /= wsum[n] when wsum[n] > 1e-11, where wsum = Σ hann² over the same frame positions

Separator (the window grid):
  after every start, seek or flush, window sizes go 64, 128, 256, 512, 512, … frames
  each window's input begins with the previous window's last OVERLAP input samples
  each window emits size*HOP - OVERLAP samples:
     if a tail exists, the first OVERLAP samples = tail + out * rise, rise = (i + 0.5)/OVERLAP
     the window's last OVERLAP samples become the next tail = out * (1 - (i + 0.5)/OVERLAP)
  at end of stream the remaining samples go out as a short last window
  at most 2 windows outstanding (queued + running + finished but not yet played)
  a flush bumps a generation counter, and results from an older generation are dropped
  passThrough (a file already saved without music): skip the model, emit the input
  failure: emit silence, never the original audio, and surface the error
  input at another rate or mono is converted to 44.1 kHz stereo first (Android interpolates
  linearly; iOS uses AVAudioConverter)
```

**Models**
- Spleeter 2-stems as exported to ONNX by sherpa-onnx. `prepare_models.py` makes the frame dimension
  (`dim[2]`) symbolic, named `frames`, and stores the weights as fp16, with the arithmetic still in
  fp32.
- Base URL: `https://github.com/yshalsager/newtube-musicless/releases/download/musicless-models-v1`.
- Files `vocals.onnx.gz` and `accompaniment.onnx.gz`. SHA-256 of the **decompressed** files:
  - vocals: `f6fce89a06c9a98846e1b38e45dcd79ade2c256c3ce11119b33474da726be552`
  - accompaniment: `5e3f3048bf2936658a9ab3a9742b2e24765a06cc6c6c7de638aa93ea86330a45`
- Download behaviour to keep:
  - resume with `Range`; a 206 must carry a matching `Content-Range`; a 416 on resume means the gzip
    is already complete;
  - cap at 100 MB;
  - stream the gunzip and the hash together;
  - publish atomically as `<sha>-<name>`;
  - delete partial files on a hash mismatch.
- On iOS, store them in Application Support with `isExcludedFromBackup`.

**ONNX Runtime session settings (Android):**
- intra-op threads 2, inter-op threads 1;
- no CPU arena, no memory pattern, `session.intra_op.allow_spinning=0`;
- optimisation `BASIC_OPT`;
- symbolic dimension `num_splits` = 1;
- telemetry off.

Loading, inference and disposal all run on one thread. Sessions are released after 2 minutes idle,
and on memory pressure when no player uses them.

**iOS backend plan (D7)**
1. ONNX Runtime from Swift Package Manager (`microsoft/onnxruntime-swift-package-manager`
   [verify the current URL and version]), CPU first.
2. The same with the CoreML execution provider (MLProgram format; compute units `ALL`, then
   `CPUAndNeuralEngine`), so it can reach the Neural Engine.
3. Only if both are too slow: convert to native Core ML (US-007). coremltools no longer reads ONNX,
   so the route is ONNX → PyTorch (onnx2torch) → coremltools, with `EnumeratedShapes` for
   F ∈ {64, 128, 256, 512} and fp16. Spleeter's U-Net (Conv2D, BatchNorm, LeakyReLU, ConvTranspose,
   concat, sigmoid) is Neural-Engine-friendly [verify]. Fusing both U-Nets and the mask into one
   model halves the dispatches.

- **DSP:** use vDSP's real FFT (`vDSP.FFT`, log2n = 12) in Float32. Android accumulates in double;
  parity tests allow float error (US-003).
- **Expected budget:** about 1,000 FFTs per 512-frame window, a few milliseconds with vDSP; the
  models dominate [verify on the device].
- **Log line, kept identical to Android:** `Window pipeline ms=P processor=I generation=G window=N
  frames=F outputStartFrame=S outputFrames=O queueMs=Q waitModelMs=L analyzeMs=A vocalsMs=V
  accompanimentMs=C maskMs=M synthesizeMs=Y otherMs=X cpuMs=T`. Add `backend=ort-cpu|ort-coreml|coreml`
  and `appState=fg|bg`.

### 4.4 The YouTube engine [repo, from LANES.md and inventory-engine.md as of 2026-09-29]

Words used here:
- **InnerTube:** YouTube's internal API.
- **/player:** its endpoint that returns stream URLs.
- **client:** an identity such as `VISIONOS` or `TVHTML5`, made of a clientName, clientVersion,
  user agent and device fields.
- **visitor data:** the anonymous identity cookie value.
- **PO token:** an anti-bot proof that some clients need.
- **SABR:** YouTube's newer server-driven streaming protocol.
- **googlevideo:** the media CDN.

**Client versions churn.** Copy the current values from MediaServiceCore's `AppClient` at port time
into one Swift table (`ClientProfile`), with a comment naming the source line and the date.

| Client | Role on the phone | Facts |
|---|---|---|
| **VISIONOS** | 1st, signed in or out | clientName `VISIONOS`, header id 101, version `1.02`, Safari-on-Mac UA, `deviceMake Apple`, `deviceModel RealityDevice17,1`, `osName visionOS`. Visitor in `context.client.visitorData` **and** the `X-Goog-Visitor-Id` header. No PO token; no cipher, so no JS player needed. 7 s timeout. Serves every ordinary category, including music, 4K, Shorts and embed-disabled videos. Refuses made-for-kids videos ("not available"). Live answers carry HLS. |
| **TV_TIZEN** (`TVHTML5`, 7, `5.20260707`, Tizen UA) | signed out: only after an anonymous content refusal. Signed in: 2nd, **with the account** | the only route that carries the OAuth account. Ciphered (signature and `n`), so it needs the JS solver on the TV player JS. Real 5-digit `signatureTimestamp`. 15 s with the account. |
| **WEB_EMBED** | 3rd | identity from the embed page `GET https://www.youtube.com/embed/<id>?html5=1` (Safari UA, `Referer: https://www.reddit.com/`), which gives visitorData and `encryptedHostFlags`; `thirdParty.embedUrl`. Needs `n` solving. About 1 answer in 3 is SABR-only + HLS. The only anonymous source for embeddable 18+ videos. 20 s. |
| **ANDROID_VR** | 4th | the live-DASH source. As a VOD route it walls (below). |
| IOS, ANDROID_REEL, MWEB, WEB, WEB_SAFARI | last | never measured to serve what the first four refuse. The web ones need PO tokens: **skip them on iOS** at first. |

- **Visitor data:** `GET https://www.youtube.com/tv` with the Fire TV UA, the stored
  `VISITOR_INFO1_LIVE` cookie and a `SOCS` consent cookie. Parse visitorData and keep it for 10 h.
  Every client uses this same value except WEB_EMBED.
- **signatureTimestamp:** every client sends it. Regex it out of the TV player JS
  (`signatureTimestamp[:=](\d{5})`); no JS execution is needed. When it's unknown the body carries
  `-1`. Measure whether VISIONOS needs the real value at all (US-008).
- **OAuth:** web clients refuse it (HTTP 400). App clients (VISIONOS, ANDROID_VR, IOS, ANDROID_REEL)
  don't take it. **So signed-in browse (Subscriptions, Home) must use the TV client's request and
  response shapes, as SmartTube does.** Port those parsers from MediaServiceCore.
- **Answers and what each does** (LANES §2.2):
  - **served:** win.
  - **content refused:** signed out, admit anonymous TV_TIZEN next, once.
  - **age gate:** walk on; stop once every source that can serve it has answered.
  - **login required:** walk on.
  - **bot check:** the circuit breaker trips only when a second video repeats it within 10 min.
  - **no delivery (SABR-only):** walk on.
  - **terminal** (removed, terminated, members only): settles on 3 identities' consensus.
  - **no response:** transport down after 2 in a row.
- **Budgets:** 45 s per walk; per attempt 7 s for app clients, 20 s for web; `/player` and `/next`
  have an 8 s request timeout.
- **The one-minute wall** (HANDOFF §34):
  - googlevideo serves exactly 60.0 s of media to a walled (visitor, client) pair, then 403s every
    request past that stream position, including seeks.
  - It hit 1 of 17 visitors on LTE and 3 of 14 on home Wi-Fi.
  - Detection: a 403 at or past 55 s of stream after requests below 60 s were served.
  - Recovery order: WEB_EMBED → anonymous TV_TIZEN → VISIONOS with a re-rolled visitor →
    ANDROID_REEL → ANDROID_VR.
  - Remember walled (visitor, client) pairs for 6 h; re-roll the visitor at most 2 times per 6 h.
  - **Repoint:** keep playing by pointing the next range request at the new answer's URL for the same
    file. It's the same file when itag, `lmt` and `clen` match; the URL's `id` changes per answer.
    Our own fetcher makes this easy: swap the base URL and continue at the same byte offset.
- **Not ported:**
  - SABR (VISIONOS's adaptive formats carry plain URLs);
  - PO-token minting (BotGuard; none of the first four clients need it);
  - casting and the lounge protocol;
  - the deferred WEB subtitle-enrichment /player call, until subtitles exist.
- **JS solver (US-016):**
  - Needed only for TV_TIZEN and WEB_EMBED. Use the same yt-dlp EJS solver bundle that
    MediaServiceCore runs in J2V8 [verify where it lives].
  - Run it in JavaScriptCore first. A third-party app's `JSContext` has no JIT (only WebKit's own
    out-of-process WebContent may JIT), so measure the solve time on the A15. Android with V8 JIT
    takes 0.2–0.6 s.
  - Above 1.5 s, move it into a hidden `WKWebView` (JIT, out of process) via
    `callAsyncJavaScript`. WebViews are suspended in the background, so solve ahead of time and
    cache.
  - Cache the player JS per player id on disk, and solved `n` values in memory.
- **Sign-in:** the TV device-code OAuth flow that SmartTube uses
  (`ui/signin/MobileSignInActivity.java`).
  - Show the code, then open `https://yt.be/activate` in an `SFSafariViewController`.
  - Poll the token endpoint, and dismiss Safari automatically once the token arrives.
  - Keep the refresh token in the Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so
    background refresh works).
- **History (signed in):** Android sends one TV /player with the account during playback when the
  winner was anonymous, then the tracking pings (LANES §3). Port it in Phase 4.
- **Networking:**
  - One URLSession for the API and one for media.
  - HTTP/2 comes from ALPN automatically; set `assumesHTTP3Capable` on googlevideo requests (QUIC,
    like Cronet).
  - `NWPathMonitor` resumes after Wi-Fi ↔ LTE changes.
  - Respect Low Data Mode (`allowsConstrainedNetworkAccess`) by lowering quality.
  - No URLCache for media.

### 4.5 Background, power, memory, thermal

- **Audio session:** `.playback` category, `.moviePlayback` mode, `UIBackgroundModes: audio`.
  - Handle interruptions (calls) and route changes (pause when headphones are unplugged).
  - Now Playing info and remote commands go through `MPNowPlayingInfoCenter` and
    `MPRemoteCommandCenter`.
- **Separation in the background:**
  - The CPU is available while audio plays.
  - **The GPU isn't:** iOS refuses background GPU work unless it's a `BGContinuedProcessingTask`
    with the `com.apple.developer.background-tasks.continued-processing.gpu` entitlement on a device
    that supports it [checked in SDK: `BGTaskRequest.h`].
  - So the Core ML compute units are `.cpuAndNeuralEngine`, not `.all`, unless the GPU proves much
    faster in the foreground and we switch models on state changes.
  - Whether the Neural Engine keeps serving a locked-screen app is **[verify]**: US-006 benchmarks
    with the screen locked.
- **Memory:**
  - The iPhone 13 mini has 4 GB. Log `os_proc_available_memory()` (US-002).
  - Budget: ≤ 700 MB physical footprint while playing.
  - Add the Increased Memory Limit capability (`com.apple.developer.kernel.increased-memory-limit`).
  - Release idle model sessions on `didReceiveMemoryWarning` (Android's `trimMemory`).
- **Thermal:** watch `ProcessInfo.thermalState`. At `.serious`, drop the video to 720p and stop
  prefetching ahead; separation continues.
- **Profiling:** `os_signpost` around each window stage, so Instruments (Time Profiler, the Core ML
  instrument for Neural Engine use, Energy, thermal) can read it.

### 4.6 Capabilities and entitlements (self-build, paid account)

| Capability / entitlement | Used for | Phase | App Review would… |
|---|---|---|---|
| Background Modes: `audio` | voices with the screen locked, PiP | 2 | allow it (but YouTube's terms forbid background play) |
| Background Modes: `processing` + `BGTaskSchedulerPermittedIdentifiers` | `BGContinuedProcessingTask` (iOS 26): finish a download's music removal after leaving the app, with system progress UI | 5 | allow it |
| `com.apple.developer.background-tasks.continued-processing.gpu` | GPU for that task, if `BGTaskScheduler.supportedResources` includes it on the A15 [verify] | 5 | allow it |
| Increased Memory Limit; Extended Virtual Addressing | headroom for two models + buffers on a 4 GB phone | 1 | allow it |
| App Groups | settings and pending links shared with the extensions | 6 | allow it |
| Share extension, plus **opening the app through the responder chain** | "Share → Musicless" opens the video | 6 | **reject** the opening trick; fine for self-build [verify on iOS 26] |
| Safari Web Extension (`*.youtube.com`) | an "Open in Musicless" button, and optional auto-redirect to `musicless://` | 6 | allow the extension, maybe not the redirect |
| Custom URL scheme `musicless://` + App Intents | Shortcuts, Back Tap, Action button | 6 | allow it |
| **Silent keep-alive audio** while a download is processed in the background (setting, off by default) | fallback when `BGContinuedProcessingTask` is refused or on iOS < 26 | 5 | **reject** |
| Clipboard read on activation ("Play copied link?") | quick open | 4 | allow it, with the paste prompt |
| `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` + `CFBundleDocumentTypes` (movie, audio) | downloads visible in Files; "Open in Musicless" from Files | 5 | allow it |
| Auto PiP, `isIdleTimerDisabled`, scene geometry for landscape | player basics | 3 | allow them |
| `VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9)`: **public on iOS 26.2+** | VP9, so 1440p/4K and better bitrates (US-034) | 6 | allow it [checked in SDK: `VTUtilities.h`] |

**Free Apple ID builders:** keep the core app signable with only Background Modes. Put App Groups,
the extensions and the memory entitlements behind `ios/Config/Paid.xcconfig`, switched on by
`PAID_TEAM = YES` in `Local.xcconfig`. Which capabilities a free Personal Team can sign is
[verify].

### 4.7 The OS ceiling: what iOS doesn't allow (don't spend time here)

| Idea | Why not |
|---|---|
| Remove music from the official YouTube app, Safari or any other app (system-wide) | iOS gives no app access to another app's audio output. Audio Unit extensions run only inside a host app. A ReplayKit broadcast extension can capture audio but can't change what plays, and it has a ~50 MB memory limit. Only a jailbreak tweak could do it. |
| Open youtube.com links in our app automatically (universal links) | requires an `apple-app-site-association` file on youtube.com. The Safari extension (US-032) is the workaround. |
| Become the default handler for YouTube links | iOS has no such default category. |
| JIT for our own JavaScriptCore | needs `dynamic-codesigning`, which third-party apps can't get. Debugger-attach tricks are fragile. Use WKWebView when speed matters. |
| Private entitlements (`com.apple.private.*`) | AMFI refuses them on non-jailbroken devices. TrollStore doesn't support iOS 26. |
| CarPlay | needs an Apple-granted entitlement, even for development. |
| Network Extension (VPN/filter) tricks | possible with a paid account, but useless here: the traffic is TLS and the audio is compressed. |
| Inject a tweak into the official YouTube app (uYou-style) | needs a decrypted copy of Google's app; out of scope for legal reasons. |

### 4.8 Repo layout

```
ios/
  README.md                 self-build guide
  CLAUDE.md                 iOS rules (§0.4) for future sessions
  project.yml               XcodeGen spec (D10)
  bootstrap.sh              checks tools, creates Local.xcconfig from the example, runs xcodegen
  Config/                   Base.xcconfig, Paid.xcconfig, Local.xcconfig.example (Local.xcconfig gitignored)
  App/                      SwiftUI app target (screens, app state, settings, localisation)
  Extensions/               ShareExtension/, SafariExtension/ (Phase 6)
  Packages/
    MusiclessCore/          Dsp, Separator, ModelStore, ModelRuntime, OfflineSeparator   (iOS 17, macOS 14)
    YouTubeEngine/          Transport, ClientProfile, Visitor, Planner, Solver, parsers, OAuth (iOS 17, macOS 14)
    MediaPipeline/          MediaFetcher, FMP4Demuxer, renderers, HoldController, PlayerEngine (iOS 17, macOS 14)
  tools/                    dsp-golden/ (Java harness), reference_two_models.py, convert_coreml.py,
                            import_android_strings.py
docs/ios/                   PRD.md (this file), DECISIONS.md, DEVICE-PROBE.md, BENCHMARKS.md
```

The packages build for macOS too, so `swift test` on the Mac covers the DSP, the separation, the
demuxer and the parsers in seconds, without a device.

---

## 5. User stories

**Definition of done for every story:**
- the build has zero warnings in Swift 6 language mode with complete strict concurrency;
- `swift test` passes for every touched package;
- the app installs and launches on the pinned iPhone;
- no file changes outside `ios/`, `docs/ios/`, `tasks/` and `.gitignore`. The root `CLAUDE.md`
  gets one pointer line in US-001.

**UI stories also:** attach simulator screenshots (`xcrun simctl io booted screenshot`) to the PR,
check the screen on the iPhone in English and Arabic, and check right-to-left layout.

### Phase 0: Groundwork

#### US-001: Project skeleton
**Description:** As a builder, I want an `ios/` folder that generates an Xcode project, so a clean
clone runs on my iPhone with only my Team ID set.

**Acceptance criteria:**
- [ ] `ios/project.yml` defines the app target `Musicless` and the three local packages (§4.8), each
  with one placeholder test. The app is iPhone only, iOS 17.0+, Swift 6.
- [ ] `Base.xcconfig` includes the optional `Local.xcconfig`, which sets `DEVELOPMENT_TEAM`,
  `BUNDLE_ID_PREFIX` and `PAID_TEAM`. A `Local.xcconfig.example` is committed.
  - Bundle id: `$(BUNDLE_ID_PREFIX).musicless`.
  - Display name: "NewTube Musicless".
- [ ] `ios/bootstrap.sh` checks for Xcode ≥ 26 and XcodeGen (with the `brew install xcodegen` hint),
  creates `Local.xcconfig` if it's missing, and runs `xcodegen generate`.
- [ ] `.gitignore` gains `ios/*.xcodeproj`, `ios/build/`, `ios/Config/Local.xcconfig`,
  `ios/.models/` and `ios/**/DerivedData`.
- [ ] The app shows a placeholder screen with its version and the git short SHA, injected by a
  build phase.
- [ ] `ios/README.md`:
  - requirements: a Mac, Xcode 26+, XcodeGen, an Apple ID. Free means re-signing every 7 days; paid
    lasts 1 year.
  - steps, Developer Mode, trusting the profile;
  - a personal-use note: build it for yourself, don't share IPAs.
- [ ] `ios/CLAUDE.md` holds §0.4, and the root `CLAUDE.md` gets one line pointing to it.
- [ ] Verified: `xcodebuild` builds for the simulator and for the pinned iPhone, and the app launches
  on both.

#### US-002: Device capability probe
**Description:** As the developer, I want a debug screen that reports what this phone's OS and
hardware allow, so later decisions rest on measurements.

**Acceptance criteria:**
- [ ] It reports:
  - iOS version, model identifier, physical memory, `os_proc_available_memory()`;
  - thermal state, Low Power Mode;
  - `VTIsHardwareDecodeSupported` for avc1, hvc1, vp09 and av01, before and after
    `VTRegisterSupplementalVideoDecoderIfAvailable` for vp09 and av01 (iOS 26.2+);
  - `MLModel.availableComputeDevices` (whether the Neural Engine is present);
  - `BGTaskScheduler.supportedResources` (iOS 26), including whether the GPU resource is available;
  - the audio session's sample rate and IO buffer duration.
- [ ] A "Copy report" button. The report also goes to the log.
- [ ] The iPhone 13 mini's report goes into `docs/ios/DEVICE-PROBE.md`, without any UDID or device
  name.

### Phase 1: Separation engine

#### US-003: DSP port with golden parity
**Description:** As the developer, I want the Swift DSP to match the Java DSP, so voices sound the
same on both platforms.

**Acceptance criteria:**
- [ ] `MusiclessCore/Dsp.swift` implements analyze and synthesize exactly as in §4.3, using vDSP.
- [ ] `ios/tools/dsp-golden/` compiles the repo's **unchanged** `MusiclessDsp.java` with a small
  harness in the same package (javac, JDK 17+, as `DspBenchmark.java` does).
  - It writes binary fixtures for F ∈ {64, 512}: the input, spec, magnitude, and the synthesize
    output for a fixed mask.
  - The input is deterministic (a seeded sine mix plus noise).
- [ ] The Swift tests match the fixtures within tolerance: magnitude and spec relative error ≤ 1e-3;
  synthesize output absolute error ≤ 1e-4 [verify that the tolerances are achievable with Float32
  vDSP; record the measured errors].
- [ ] A Mac benchmark test prints analyze and synthesize time for F = 512.

#### US-004: Model store
**Description:** As a user, I want the voice models downloaded once and verified, so music removal
works offline afterwards.

**Acceptance criteria:**
- [ ] Downloads both `.onnx.gz` files from the base URL (Info.plist key `MusiclessModelBaseURL`,
  default as in §4.3), with every download behaviour listed there.
- [ ] Hashing uses CryptoKit SHA-256. Files land in Application Support/musicless with
  `isExcludedFromBackup = true`.
- [ ] An observable status: `notDownloaded`, `downloading(percent)`, `ready`, `failed(message)`,
  with retry.
- [ ] Tests use a `URLProtocol` stub and cover a fresh download, resume (206), a 416 on resume, a bad
  `Content-Range`, a hash mismatch (files deleted, failed), and the size cap.

#### US-005: Separator with ONNX Runtime
**Description:** As the developer, I want a separation engine that turns PCM into voices with
Android's window grid, so the player and downloads can share it.

**Acceptance criteria:**
- [ ] ONNX Runtime comes in through SPM. Sessions use the settings in §4.3, loaded and run on one
  serial executor (`ModelRuntime` actor). Loading happens once, sessions are released after 120 s
  idle, and on memory warnings when idle.
- [ ] `Separator` API: `configure(sampleRate:channels:)`, `enqueue(_:)`, `flush()`, `endOfStream()`,
  and an async stream of `(startFrame, voices)` chunks. It implements the ramp, ≤ 2 outstanding
  windows, crossfade, generations, passThrough, and failure → silence.
- [ ] `ios/tools/reference_two_models.py` (numpy + onnxruntime) mirrors the Java pipeline with the
  two release models and the ramped grid. `tools/musicless/reference.py` is the starting point, but
  it uses a different single-model file.
- [ ] A macOS `swift test` separates a 30 s CC-licensed clip end to end, and the voices differ from
  the Python reference by an SNR of ≥ 35 dB [verify the threshold; record it]. The clip's licence
  goes in the fixture folder.
- [ ] Each window logs the `Window pipeline …` line (§4.3).

#### US-006: On-device benchmark and the backend decision
**Description:** As the developer, I want measured separation speed on the iPhone, so the backend
choice (D7) rests on data.

**Acceptance criteria:**
- [ ] A debug screen runs 10 windows of F = 64 and 10 of F = 512 on a bundled clip with:
  - ORT CPU;
  - ORT + CoreML EP (compute units `ALL`);
  - ORT + CoreML EP (`CPUAndNeuralEngine`).
  Each runs **in the foreground and with the screen locked**; while locked, the audio session plays
  silence to stay alive.
- [ ] It records per-stage milliseconds, model load and compile time (first and cached), thermal
  state and memory footprint, as CSV in Documents, visible in Files.
- [ ] The results and decision D-backend go into `docs/ios/BENCHMARKS.md` and `DECISIONS.md`.
- [ ] Gate: if the best configuration takes over 3,000 ms per F = 512 window in the foreground, or
  over 6,000 ms locked, do US-007 before Phase 2.

#### US-007 (conditional): Native Core ML model
**Description:** As the developer, I want a Neural-Engine-friendly Core ML model if ONNX Runtime is
too slow.

**Acceptance criteria:**
- [ ] `ios/tools/convert_coreml.py` follows §4.3's route: EnumeratedShapes, fp16, optionally one
  fused model that outputs v and a (or the mask).
- [ ] Its output matches the ORT model's within the US-005 SNR threshold.
- [ ] The app compiles the `.mlpackage` once on the device and caches the `.mlmodelc`.
- [ ] Hosting: zipped `.mlpackage` files as a new release asset set `musicless-models-ios-v1` with
  pinned hashes. The repo owner uploads them; until then a local build phase fetches them.
- [ ] US-006 re-run and recorded.

### Phase 2: Playback proof of concept

#### US-008: InnerTube transport and visitor identity
**Description:** As the engine, I want correct client contexts and an anonymous identity, so
/player answers like it does on Android.

**Acceptance criteria:**
- [ ] A `ClientProfile` table copied from MediaServiceCore (§4.4), with the source line and date in
  comments. Request bodies are byte-compatible with what MediaServiceCore's QueryBuilder produces for
  VISIONOS; a test compares them against a body reconstructed from the Java code.
- [ ] The visitor comes from `youtube.com/tv` (§4.4), persisted 10 h, and sent in the context and
  in `X-Goog-Visitor-Id`.
- [ ] `signatureTimestamp` comes from the TV player JS by regex, cached per player URL.
- [ ] Measured on the device: whether VISIONOS serves with `sts = -1`. Recorded in DECISIONS.
- [ ] Every API request logs `api client=… status=… ms=… protocol=…`, and the protocol is `h2` (or
  `h3`).

#### US-009: VISIONOS /player and format selection
**Description:** As the player, I want to turn a video id into one H.264 and one AAC stream, or a
clear refusal.

**Acceptance criteria:**
- [ ] Parses:
  - `playabilityStatus` (status, reason, subreason);
  - `videoDetails` (id, title, author, channelId, lengthSeconds, isLive, thumbnails);
  - `streamingData.adaptiveFormats` (itag, mimeType, bitrate, width, height, fps, initRange,
    indexRange, contentLength, lastModified, url, audioSampleRate, audioChannels, approxDurationMs);
  - `hlsManifestUrl`, and the SABR marker `serverAbrStreamingUrl`.
- [ ] Classifies answers into the LANES §2.2 kinds.
- [ ] Selection:
  - video: the best avc1 at or below min(screen height, user cap, 1080), fps ≤ 60;
  - audio: the highest-bitrate `mp4a.40.2` at 44.1 kHz, falling back to any mp4a.
- [ ] Tests on 5 recorded answers: ordinary, kids refused, 18+ age gate, SABR-only, live. Fixtures
  are scrubbed of visitor ids.
- [ ] On the device, 10 ordinary videos each resolve with one request.

#### US-010: Media fetcher
**Description:** As the pipeline, I want media bytes fetched the way googlevideo expects, with
routine 403s surfaced for recovery.

**Acceptance criteria:**
- [ ] Byte ranges use a `Range` header only. The first chunk is small (≈ 256 KB, for a fast start),
  then chunks grow up to 2 MiB [tune; record]. `assumesHTTP3Capable` is set.
- [ ] A 403 becomes a typed `MediaRefused(itag, streamPosition, url)` error and is **never retried
  on the same URL**. Timeouts and 5xx get bounded retries with backoff. `NWPathMonitor` resumes
  after network changes.
- [ ] `repoint(to:)` swaps the URL for the same file (itag, lmt and clen must match) and continues at
  the same byte offset.
- [ ] `URLProtocol`-stub tests cover ranges, a 403, repoint and resume.

#### US-011: fMP4 demuxer
**Description:** As the pipeline, I want YouTube's fragmented MP4 turned into sample buffers.

**Acceptance criteria:**
- [ ] Parses:
  - `ftyp` and `moov` (trak, mdia, hdlr, and stsd with avc1/avcC and mp4a/esds; mvex/trex; elst);
  - `sidx` references (size, duration, SAP);
  - `moof` (tfhd, tfdt, trun) + `mdat`.
- [ ] Output:
  - CMSampleBuffers with PTS, DTS, duration and sync flags;
  - the video format description from SPS/PPS (`CMVideoFormatDescriptionCreateFromH264ParameterSets`);
  - the audio format description from the AudioSpecificConfig;
  - AAC priming exposed so it can be trimmed (§4.2).
- [ ] `seek(to:)` maps a time to a sidx segment and its byte range.
- [ ] Tests on small committed fixtures (≤ 2 MB total): init, sidx and two segments of itag 140 and
  an avc1 itag, from a CC BY video (for example a Blender Foundation film). Licence noted.

#### US-012: Audio with music removed (audio-only proof)
**Description:** As a user, I want to hear only the voices of a YouTube video, even with the screen
locked.

**Acceptance criteria:**
- [ ] Pipeline: fetch → demux → `AVAudioConverter` (to Float32, 44.1 kHz, stereo; priming trimmed)
  → Separator → LPCM CMSampleBuffers → `AVSampleBufferAudioRenderer` on an
  `AVSampleBufferRenderSynchronizer`.
- [ ] Hold:
  - rate 0 until the first window is ready;
  - later, a hold when less than 0.25 s is enqueued ahead and the Separator is still working,
    debounced 100 ms (Android's `HoldDebounce`);
  - each hold logs `hold reason=start|seek|underrun waitInputMs=… queueMs=… waitModelMs=… inferMs=… totalMs=…`.
- [ ] Audio session and background mode as in §4.5. Playback continues across a screen lock.
- [ ] Manual check on 3 music-heavy videos, listed in the PR: no music audible.

#### US-013: Video, sync and seek
**Description:** As a user, I want the picture in sync with the voices, and seeking that works.

**Acceptance criteria:**
- [ ] H.264 samples go to `AVSampleBufferDisplayLayer` (its `sampleBufferRenderer`) on the same
  synchronizer, pulled with `requestMediaDataWhenReady`. The video holds with the audio.
- [ ] Seek follows §4.2 and is ready within 1.5 s on Wi-Fi (median of 10 seeks).
- [ ] Background without PiP stops the video fetch. On return, the picture is back and in sync
  within 1 s.
- [ ] A/V offset ≤ 40 ms, measured with an A/V sync test video by logging the renderer timestamps
  against the synchronizer time, plus one slow-motion screen recording.

#### US-014: Debug watch screen (proof-of-concept milestone)
**Description:** As the developer, I want to paste a link and watch it without music, to prove the
whole path on the iPhone.

**Acceptance criteria:**
- [ ] Accepts `watch?v=`, `youtu.be/`, `shorts/`, `embed/` and `m.youtube.com` forms, and bare ids.
- [ ] Controls: play/pause, a seek bar, a quality picker (avc1 options), and a "Remove music" switch
  that toggles separation ↔ passthrough with a flush, without rebuilding the player.
- [ ] Shows a "Preparing voices…" overlay while holding. While the models download, the screen
  shows their progress and playback waits.
- [ ] A demo screen recording from the iPhone goes in the PR. This story ends PR B (§12).

### Phase 3: Robust playback and system integration

#### US-015: Source walk (signed-out lane)
**Acceptance criteria:**
- [ ] Ports PhoneSourcePlanner's signed-out lane as in §4.4:
  - the order VISIONOS → (anonymous TV_TIZEN after a refusal) → WEB_EMBED (embed identity) →
    ANDROID_VR → ANDROID_REEL → IOS;
  - the answer kinds, the age-gate stop, terminal consensus, the bot-check rule, budgets and
    timeouts.
- [ ] Replay tests built from recorded answers, mirroring Android's walk replay tests [verify their
  names in MediaServiceCore].
- [ ] On the device, a made-for-kids video plays via anonymous TV_TIZEN at request 2.

#### US-016: Signature and n solver
**Acceptance criteria:**
- [ ] The EJS solver bundle (the same one MediaServiceCore uses) runs in JavaScriptCore on its own
  thread and solves `s` and `n` for TV_TIZEN and WEB_EMBED answers.
- [ ] Solve time measured on the A15, cold and with a warm cache, and recorded. Above 1.5 s, it moves
  to a hidden WKWebView (§4.4).
- [ ] Player JS is cached on disk per player id; solved values in memory.

#### US-017: 403 recovery and the one-minute wall
**Acceptance criteria:**
- [ ] A media 403 triggers a walk for the same itags with the failing client moved last. The fetcher
  repoints with no visible stop when the new answer has the same file.
- [ ] Wall detection, the recovery order, 6 h wall memory and visitor re-roll exactly as in §4.4.
  Logs: `playback-media403 … signature=wall|ordinary`, `wall-swap …`.
- [ ] A synthetic wall setting (a debug option that answers 403 past 60 s of stream) proves recovery
  without an error or rewind, 4 out of 4 times.

#### US-018: System player integration
**Acceptance criteria:**
- [ ] Now Playing: title, channel, artwork, position, rate. Remote commands: play, pause,
  skip ±10 s, scrub.
- [ ] PiP from the sample buffer layer, including auto-start when swiping home. PiP keeps the video
  decoding.
- [ ] Interruptions (a phone call) pause and resume. Unplugging headphones pauses.
- [ ] Full-screen landscape. The screen doesn't sleep while video plays.
- [ ] Playback speed 0.5–2× through the synchronizer rate (`audioTimePitchAlgorithm = .timeDomain`
  for speech) [verify which algorithm sounds better].

### Phase 4: App UI

#### US-019: Search
- [ ] Ports MediaServiceCore's search request and parser (the TV client shapes): a results list with
  thumbnails, duration, channel and age, plus continuation paging.
- [ ] [UI] Search history stored locally, clearable.

#### US-020: Watch page
- [ ] The player on top. Below it: title, channel (tappable), views and date, an expandable
  description, and related videos from `/next`.
- [ ] Up next is hidden by default (the fork's default `PlayerTweaksData`); a setting shows it. The
  player pauses when a video ends (the fork's default `PlayerData`).
- [ ] [UI] Portrait, plus landscape full screen.

#### US-021: Channel page
- [ ] Header (name, avatar, subscriber count) and an uploads list with paging.

#### US-022: Sign-in
- [ ] The device-code flow as in §4.4, with sign-out. Tokens live in the Keychain only and are never
  logged.
- [ ] After sign-in, playback follows the signed-in lane (TV_TIZEN with the account second), and
  history is sent as Android does (§4.4).

#### US-023: Subscriptions and Home
- [ ] Subscriptions feed (signed in), the first tab by default. Home is hidden by default (the fork's
  default) and can be enabled in Settings.
- [ ] Signed out, Subscriptions shows a sign-in prompt.

#### US-024: Settings
- [ ] Remove music (on by default) and the voice model status (size, retry, re-download).
- [ ] Maximum quality, prefer 60 fps, background play on/off.
- [ ] Language: a row that opens the app's page in iOS Settings, where per-app language lives.
- [ ] About, with the licences shipped from `smarttubetv/src/stmobile/assets/musicless/`: Musicless,
  Spleeter, ONNX Runtime and its third-party notices, NOTICE.
- [ ] A debug section: the probe, the benchmark, the synthetic wall, log export.

#### US-025: Arabic and RTL
- [ ] `ios/tools/import_android_strings.py` converts the matching keys from
  `values/strings_mobile.xml`, `values-ar/strings_mobile.xml` and `strings_settings.xml` into
  `Localizable.xcstrings`, keeping the Android key as the comment.
- [ ] Every screen is checked in Arabic with right-to-left layout. Numbers and durations are
  formatted per locale.

#### US-026: Comments (read-only)
- [ ] Top comments and replies with paging, under the watch page.

### Phase 5: Files and downloads

#### US-027: Open local files
- [ ] Opens files from the document picker and from "Open in" in Files and other apps
  (`CFBundleDocumentTypes` for movie and audio).
- [ ] An `AVAssetReader` source feeds the same Separator and renderers. This is the Android
  `d074c0c6` behaviour: local files get music removal too.

#### US-028: Download with music removed
- [ ] Pick a quality, then fetch the video and audio with a background `URLSession`, using the same
  403 recovery as playback (re-resolve the same itags; never retry a refused URL).
- [ ] With Remove music on:
  - the audio goes through `OfflineSeparator` (AVAssetReader → Separator → AAC-LC 128 kb/s with
    AVAssetWriter) and is muxed with the video into one MP4;
  - the item is marked `voicesOnly`, and playing it uses passThrough;
  - if separation fails, the download fails with "Couldn't remove the music". It never saves a file
    with music or silence.
- [ ] On iOS 26, the processing runs as a `BGContinuedProcessingTask` with system progress.
  Otherwise it runs in the foreground, plus the US-029 fallback.
- [ ] While a video plays, the download feeds the model only when its thread is idle (Android's
  rule).
- [ ] Finished files appear in Files → On My iPhone → NewTube Musicless.

#### US-029 (optional): Keep-alive fallback
- [ ] A setting, off by default: while a download is being processed in the background and
  `BGContinuedProcessingTask` isn't available, play silent audio to keep the app running. It stops
  as soon as the work ends. The battery cost is stated next to the switch.

### Phase 6: OS integrations

#### US-030: URL scheme and App Intents
- [ ] `musicless://watch?v=ID`. App Intents "Open in Musicless (URL)" and "Play copied link" appear
  in Shortcuts, so they work from Back Tap and the Action button.

#### US-031: Share extension
- [ ] "Share → NewTube Musicless" from Safari, the YouTube app or Messages opens the video in the app.
  The link goes through the App Group, and the app opens via the responder chain [verify on
  iOS 26]. If opening fails, the extension says "Link saved, open NewTube Musicless" and the app
  picks it up on activation.

#### US-032: Safari Web Extension
- [ ] On `youtube.com` and `m.youtube.com` watch and Shorts pages, it adds an "Open in Musicless"
  button. An optional setting redirects automatically to `musicless://` (Safari asks for
  confirmation).

#### US-033 (optional): Live Activity for downloads
- [ ] Download and processing progress on the Lock Screen and in the Dynamic Island (ActivityKit).

#### US-034 (optional): VP9 above 1080p
- [ ] When the US-002 probe shows VP9 decoding after `VTRegisterSupplementalVideoDecoderIfAvailable`
  (iOS 26.2+): add a WebM demuxer for VP9 itags, and offer 1440p/4K. Feeding VP9 to the display layer
  is [verify]; if it doesn't work, decode with `VTDecompressionSession` and enqueue the decoded
  frames.

#### US-035 (optional): CI
- [ ] `.github/workflows/ios.yml` on a macOS runner: `swift test` for each package, plus a simulator
  build with `CODE_SIGNING_ALLOWED=NO`, only on changes under `ios/`.

---

## 6. Functional requirements

**Music removal**
- FR-1: With Remove music on (the default), every YouTube video and local file plays through the
  Separator. The user never hears the original audio unless they turn Remove music off.
- FR-2: If separation fails, the audio is silent and an error with a retry shows. The original audio
  is never played as a fallback.
- FR-3: Until the voice models are ready, playback waits and shows download progress (Android's
  `MusiclessDownloadGate`).
- FR-4: While voices aren't ready (start, seek, underrun), the clock stops (rate 0) and "Preparing
  voices…" shows after 100 ms. Video never runs ahead of the voices.
- FR-5: Toggling Remove music during playback switches with a flush at the current position. The
  player isn't rebuilt.
- FR-6: Files saved with the music removed are marked voices-only and play without the model.

**Playback**
- FR-7: Video is H.264 at up to 1080p60 by default, capped by settings, Low Data Mode and thermal
  state. Audio is AAC (mp4a.40.2).
- FR-8: Audio continues with the screen locked and in the background. Video continues in PiP.
- FR-9: Seek, playback speed, Now Playing and remote commands work as in US-018.
- FR-10: A/V offset stays within 40 ms; AAC priming is trimmed.

**YouTube engine**
- FR-11: /player walks clients in the LANES order (§4.4). VISIONOS is first.
- FR-12: Media byte ranges use only the `Range` header.
- FR-13: A media 403 is never retried on the same URL. It triggers re-resolution of the same itags
  and a repoint when the file matches.
- FR-14: The one-minute wall is detected and recovered from as in §4.4, without stopping playback.
- FR-15: Every API request runs over HTTP/2 or HTTP/3, and its protocol is logged.
- FR-16: Visitor data persists 10 h. The visitor is re-rolled only by wall recovery, at most twice
  per 6 h.
- FR-17: Signed in, OAuth tokens are sent only on the account route (TV_TIZEN) and TV-shaped browse
  requests, never on web or app clients.

**App**
- FR-18: Tabs: Subscriptions (first), Search, You (downloads, open a file, settings, account). Home
  is optional, off by default.
- FR-19: The UI follows the device language, with English and Arabic and full right-to-left layout.
  The language row opens iOS Settings.
- FR-20: Settings and pending links are shared with the extensions through the App Group when
  `PAID_TEAM` is on.
- FR-21: No analytics or telemetry of any kind (ONNX Runtime telemetry off). Logs never contain
  tokens, and visitor ids are truncated to 10 characters.
- FR-22: About shows every third-party licence (§US-024).

**Files**
- FR-23: Downloads are stored in Documents, visible in Files. Local files open from Files, "Open in"
  and the document picker.
- FR-24: Download processing follows US-028, including its failure rule.

## 7. Non-goals (out of scope)

- App Store, TestFlight, AltStore or IPA distribution; release signing in CI; an in-app updater.
- iPad layouts, Mac Catalyst, visionOS, tvOS, CarPlay.
- Live streams in the first release (Android lists them as untested too). Possible later: VISIONOS
  HLS live parsed by our own pipeline.
- VP9 and AV1 before US-034; HDR; 4K by default.
- SABR, PO-token minting, the web clients that need tokens.
- Casting (Chromecast, the lounge protocol, AirPlay video). AirPlay audio works through the audio
  renderer.
- Posting comments, live chat, notifications, Shorts-specific UI, playlists editing, uploads.
- SponsorBlock, DeArrow and Return YouTube Dislike in the first release (SmartTube has them; a later
  phase can port them). Use the video's own thumbnails meanwhile, as the fork's DeArrow default does.
- System-wide music removal, and modifying the official YouTube app (§4.7).

## 8. Design considerations

- **Mirror the Android phone app's structure**, using native iOS components (`NavigationStack`,
  `TabView`, `List`, sheets):

  | Android | iOS |
  |---|---|
  | `ui/browse` | tabs |
  | `ui/playback` | watch page and player |
  | `ui/search` | Search |
  | `ui/channel` | Channel |
  | `ui/signin` | sign-in sheet |
  | `ui/settings` | Settings |
  | `downloads` | You → Downloads |
  | `localmedia` | You → Open a file |

- **Dark theme first,** like the Android app (surfaces around `#1E1E1E`). The accent is the fork's
  emerald, from the icon in `smarttubetv/src/musicless/res`. Convert that icon to a 1024 px app icon
  (the drawable folder may hold a vector; otherwise use the xxxhdpi mipmap).
- **Player overlay:** play/pause, a seek bar with chapters later, a "Remove music" switch in the
  player's menu (Android's gear-menu row), quality, speed, PiP, full screen.
- **Holds** show "Preparing voices…" over the frozen frame.
- **Dynamic Type and VoiceOver labels** on every control.
- **Thumbnails:** use a memory and disk cache (`URLCache` with a dedicated size, or a small own
  cache). Don't add an image library unless needed.

## 9. Risks

| Risk | Impact | Mitigation |
|---|---|---|
| Separation too slow on the A15, or the Neural Engine unavailable when locked | stalls; no background play | US-006 gate; Core ML conversion (US-007); a fused model; CPU fallback with longer look-ahead |
| YouTube changes clients or versions | /player fails | one `ClientProfile` table resynced from MediaServiceCore; the walk falls through; the Android project measures first |
| The VISIONOS answer differs from an iPhone (Apple TLS stack, iOS IP, URLSession fingerprint) | first-client misses | measure in US-009. VISIONOS uses a Safari UA, so Apple's TLS stack may even fit better [verify] |
| JavaScriptCore without JIT too slow for the solver | slow kids and 18+ starts | the WKWebView fallback; caching; VISIONOS needs no solver |
| Demuxer edge cases (edit lists, odd trun flags, missing sidx) | glitches | fixtures from many videos; plan B (AVPlayer + AVAudioEngine) or libavformat |
| Display layer failures in the background | black video on return | stop feeding in the background; flush and resync on return (§4.2) |
| Memory on a 4 GB phone | jetsam kills | the 700 MB budget, Increased Memory Limit, idle release |
| Xcode 26.4 vs iOS 26.6.2 on the device | can't install | [verify] in US-001; update Xcode if needed |
| The repo owner doesn't want iOS in `musicless` | PR not merged | ask first (§0.1 step 5); a long-running `ios` branch or a separate repo also works |
| Legal: YouTube's terms forbid third-party clients that remove ads, download or play in the background | takedown | personal self-build only; no binaries published |

## 10. Success metrics

Measured on the iPhone 13 mini and recorded in `docs/ios/BENCHMARKS.md`:

**Separation throughput**
- F = 512 window: ≤ 3,000 ms in the foreground (≥ 4× real time); ≤ 6,000 ms with the screen locked.
- First (F = 64) window: ≤ 400 ms.

**Start and stalls**
- Tap → first voices: median ≤ 2.5 s, p90 ≤ 4 s on home Wi-Fi, over 10 ordinary videos.
- Holds after the start: 0 on Wi-Fi for a 10-minute 1080p video; ≤ 1 on LTE.

**Sync and stability**
- A/V offset ≤ 40 ms.
- 60 minutes of continuous playback, including 10 minutes locked and 10 in PiP:
  - no crash;
  - peak footprint ≤ 700 MB;
  - thermal state never `.critical`, and `.serious` for at most 5 minutes.

**Other**
- Battery drain per hour recorded (screen at 50 %, 1080p, Remove music on). No gate yet; compare
  against Remove music off.
- Self-build: a fresh clone → the app on a phone in ≤ 20 minutes, following `ios/README.md`.

## 11. Verification playbook

```bash
# One-time: find the ids (put them in your shell, never in committed files)
xcrun devicectl list devices          # CoreDevice id  -> $DEVICE_ID   (devicectl)
xcrun xctrace list devices            # hardware UDID  -> $IOS_UDID    (xcodebuild)

# Generate the project and test the packages on the Mac
(cd ios && ./bootstrap.sh)
swift test --package-path ios/Packages/MusiclessCore
swift test --package-path ios/Packages/YouTubeEngine
swift test --package-path ios/Packages/MediaPipeline

# Simulator build, run and screenshot (UI only; no separation timing here)
xcrun simctl list devices available
xcodebuild -project ios/Musicless.xcodeproj -scheme Musicless \
  -destination 'platform=iOS Simulator,name=<a device from the list>' -derivedDataPath ios/build build
xcrun simctl install booted ios/build/Build/Products/Debug-iphonesimulator/Musicless.app
xcrun simctl launch --console booted "$BUNDLE_ID"
xcrun simctl io booted screenshot /tmp/screen.png

# Device build, install and launch with the console attached (pinned device)
xcodebuild -project ios/Musicless.xcodeproj -scheme Musicless \
  -destination "platform=iOS,id=$IOS_UDID" -derivedDataPath ios/build -allowProvisioningUpdates build
xcrun devicectl device install app --device "$DEVICE_ID" ios/build/Build/Products/Debug-iphoneos/Musicless.app
xcrun devicectl device process launch --device "$DEVICE_ID" --console "$BUNDLE_ID"

# Profiling (Neural Engine use, CPU, energy)
xcrun xctrace record --template 'Time Profiler' --device "$IOS_UDID" --attach Musicless --time-limit 60s
```

- **Logs:** OSLog with subsystem = bundle id, categories `Musicless`, `NetPath`, `Player`. In Debug
  builds, mirror each line to stdout so `devicectl … --console` shows it. Console.app with the phone
  selected also works.
- **Golden data:** `ios/tools/dsp-golden` (Java) for the DSP; `ios/tools/reference_two_models.py`
  for end-to-end separation.
- **Ear test:** 3 music-heavy videos per playback PR, listed by URL in the PR description.

## 12. PR plan

Each PR goes from the developer's fork, branch `ios/<phase>`, to `yshalsager/newtube-musicless`,
base `musicless`. Each touches only `ios/`, `docs/ios/`, `tasks/`, `.gitignore`, plus one pointer
line in the root `CLAUDE.md`.

| PR | Stories | It's done when |
|---|---|---|
| A | US-001 – US-007 | the skeleton runs; separation matches the Java and Python references; the device benchmark is recorded; the backend is decided |
| B | US-008 – US-014 | paste a link and watch it on the iPhone without music, in sync, with the screen lockable (demo video) |
| C | US-015 – US-018 | kids, 18+ and walled videos play; PiP, Now Playing, speed |
| D | US-019 – US-026 | search, watch page, channel, sign-in, feeds, settings, Arabic |
| E | US-027 – US-029 | local files; downloads without music, visible in Files |
| F | US-030 – US-035 | share sheet, Shortcuts, Safari extension, optional extras |

## 13. Open questions

| # | Question | Recommendation |
|---|---|---|
| Q1 | ONNX Runtime or native Core ML? | decided by US-006 data |
| Q2 | Download the models at runtime (as Android does) or bundle them at build time? | runtime download, for parity and a smaller build; revisit if Core ML needs different files |
| Q3 | The Android fork forces Arabic on first run. On iOS? | follow the device language and offer the iOS Settings language row. Forcing `AppleLanguages` works but is a hack |
| Q4 | Commit the generated `.xcodeproj`, or require XcodeGen? | require XcodeGen (one `brew install`); no pbxproj conflicts |
| Q5 | Will the repo owner accept iOS in `musicless`? | ask before PR A |
| Q6 | Does VISIONOS behave the same from an iPhone? | measure in US-009 |
| Q7 | Minimum iOS: 17 or 26? | 17 lets more builders in; 26 is simpler if it's only for you. Decide in US-001 |
| Q8 | Which capabilities can a free Personal Team sign? | test in US-001 with a free account; keep the core free-signable |
| Q9 | App name and bundle prefix for your build | "NewTube Musicless", `io.github.<you>.musicless` |

---

## Appendix A: environment checked on 2026-11-25

**Mac**
- Xcode 26.4 (17E192): iOS SDK 26.4, simulator runtime 26.4.
- Swift 6.3.
- XcodeGen (Homebrew), Python 3.11, JDK 17 and 25.

**iPhone**
- iPhone 13 mini (iPhone14,4): A15 Bionic, 4 GB RAM, 16-core Neural Engine.
- iOS 26.6.2, Developer Mode enabled, paired with the Mac.
- Developer disk image services weren't mounted yet; Xcode mounts them on the first run.

**iOS 26.4 SDK headers:**
- `VTRegisterSupplementalVideoDecoderIfAvailable`: iOS 26.2+.
- `VTIsHardwareDecodeSupported`: iOS 11+.
- `BGContinuedProcessingTaskRequestResources.gpu`, `requiredResources`, and
  `BGTaskScheduler.supportedResources` (iOS 26), plus the entitlement
  `com.apple.developer.background-tasks.continued-processing.gpu`.
- `AVPictureInPictureControllerContentSource initWithSampleBufferDisplayLayer:playbackDelegate:`.
- `AVSampleBufferVideoRenderer`.
- `AVSampleBufferRenderSynchronizer` and `AVSampleBufferAudioRenderer` (iOS 11+).
- `MLNeuralEngineComputeDevice`.
- `kCMVideoCodecType_VP9`, `kCMVideoCodecType_AV1`, `kAudioFormatOpus`.

## Appendix B: sources in this repo

| Topic | Where |
|---|---|
| Music removal: design, models, fork defaults, releases | `docs/musicless/HANDOFF.md`, `docs/musicless/FEASIBILITY.md` |
| Music removal: code and tests | `smarttubetv/src/stmobile/java/com/newtube/mobile/player/Musicless*.java`, `smarttubetv/src/test/java/com/newtube/mobile/player/Musicless*Test.java` |
| Offline reference, benchmark, model export | `tools/musicless/` |
| Client order, answers, recovery | `docs/player-sources/LANES.md`, `DESIGN.md`, `PLANNER.md` |
| Client identities and request bodies | `docs/player-sources/inventory-engine.md` §1 |
| PO tokens (for later) | `docs/player-sources/potoken-port.md` |
| Network, SABR, the one-minute wall | `docs/mobile-port/HANDOFF.md` §3, §8, §26–28, §34 |
| Downloads and 403 recovery outside the player | `smarttubetv/src/stmobile/java/com/newtube/mobile/downloads/` (`StreamFetcher`, `DownloadJob`) |
| Local files | `smarttubetv/src/stmobile/java/com/newtube/mobile/localmedia/` |
| Sign-in flow | `smarttubetv/src/stmobile/java/com/newtube/mobile/ui/signin/MobileSignInActivity.java` |
| Strings (English and Arabic) | `smarttubetv/src/stmobile/res/values{,-ar}/` |
| Licences to ship | `smarttubetv/src/stmobile/assets/musicless/` |
