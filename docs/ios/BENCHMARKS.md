# iOS benchmarks

Measurements on the test phone (iPhone 13 mini, A15, iOS 26.6.2) unless a row says otherwise.
Separation speed is only measured on the iPhone (`ios/CLAUDE.md`).

## US-006: separation backends (2026-11-25)

**Method.** Release build of the Phase 1 tree (`7ed92917` + Phase 0/1 work, uncommitted at the time),
debug screen Separation benchmark, launched with
`devicectl device process launch --console <bundle id> --console-log --benchmark` (foreground) and
`--benchmark-locked` (plays silence, waits until the app is backgrounded by the screen lock, then
runs). Per backend: model load from an empty CoreML cache ("first"), close, load again ("cached");
then 10 windows of 64 frames and 10 of 512 frames (1.49 s and 11.89 s of audio), back to back,
through `ModelRuntime.separate` (DSP + both models + mask, the same code playback uses). Input: a
deterministic tone-and-noise signal (DECISIONS D33). Medians exclude each size's first window.
Phone on Wi-Fi, thermal state nominal throughout. Raw CSVs: Documents on the phone,
`benchmark-2026-11-25T141344-fg.csv` and `benchmark-2026-11-25T141712-locked.csv`.

### Foreground

| Backend | Load first / cached | F=64 first / median | F=512 first / median | F=512 stages (median) | Peak footprint |
|---|---|---|---|---|---|
| **ORT CPU** | **131 / 54 ms** | **38 / 30 ms** | **265 / 258 ms** | analyze 6, vocals 121, accompaniment 121, mask 0, synthesize 6 | **108 MB** |
| ORT + CoreML EP, `ALL` | 1864 / 960 ms | 1827 / 88 ms | 572 / 378 ms | analyze 10, vocals 162, accompaniment 200, synthesize 12; thread CPU 127 ms (GPU) | 450 MB |
| ORT + CoreML EP, `CPUAndNeuralEngine` | 1390 / 799 ms | 284 / 22 ms | 322 / 153 ms | analyze 6, vocals 69, accompaniment 69, synthesize 6; thread CPU 153 ms | 572 MB |

### Screen locked (app in the background, silent audio playing)

| Backend | Load first / cached | F=64 first / median | F=512 first / median | Peak footprint |
|---|---|---|---|---|
| **ORT CPU** | 145 / 54 ms | 32 / 29 ms | 261 / 264 ms | 116 MB |
| ORT + CoreML EP, `ALL` | 2175 / 1022 ms | **fails**: "Error executing model: Error in dynamically resizing for sequence length (error: -6)" on every window | — | — |
| ORT + CoreML EP, `CPUAndNeuralEngine` | 1513 / 845 ms | 323 / 23 ms | 355 / 158 ms | 565 MB |

### Reading

- **Gate (US-006):** the best configuration must take ≤ 3,000 ms per F=512 window in the foreground
  and ≤ 6,000 ms locked, or US-007 comes first. ORT CPU takes 258 ms and 264 ms: about 46× real time,
  more than 10× inside the gate. **US-007 (native Core ML) is not needed.**
- **Success metrics (PRD §10):** F=512 ≤ 3,000 ms foreground / ≤ 6,000 ms locked: met (258 / 264 ms).
  First (F=64) window ≤ 400 ms: met (38 ms, plus 131 ms for the first model load).
- **The models dominate**, as §4.3 expected: the vDSP analyze + synthesize take 12 ms of a 258 ms
  window.
- **Locked = foreground on the CPU.** iOS gives the CPU to a backgrounded app that plays audio; the
  ORT CPU figures don't move.
- **No GPU in the background,** confirmed: the CoreML `ALL` sessions load but every inference fails
  once the screen is locked.
- **The Neural Engine is not proven.** The `CPUAndNeuralEngine` sessions are faster per window
  (153 ms), but their thread CPU time equals their wall time, so Core ML probably ran them on the CPU
  (the model's `frames` dimension is dynamic, which the Neural Engine handles poorly). Instruments'
  Core ML template would tell. They also cost 1.4 s to load, 284–355 ms for the first window of each
  shape, and 5× the memory.
- **Decision:** ORT CPU is the backend (DECISIONS D34). Revisit Core ML only for energy: battery per
  hour is a PRD §10 metric (no gate), and a static-shape Core ML model on the Neural Engine may draw
  less power.

## US-003: DSP on the Mac (2026-11-25)

Apple M4, `swift test -c release --filter DspBenchmark`, F=512, median of 9 after 3 warm-up:
analyze 4.29 ms, synthesize 4.35 ms. The repo's Java DSP (`tools/musicless/DspBenchmark.java`, JDK 17)
on the same Mac: 96.2 ms for analyze + synthesize.

## US-005: end-to-end separation on the Mac (2026-11-25)

30 s of the Sintel trailer through `Separator` + `ModelRuntime` (ORT CPU, debug build): 0.47 s on an
Apple M4; 0.88 s for the same test on the iOS 26.4 simulator (the Mac's CPU, not the phone's).
