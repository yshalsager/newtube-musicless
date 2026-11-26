# Separation fixture: licence and provenance

The end-to-end separation test (`SeparationEndToEndTests.swift`, US-005) uses 30 seconds of the
**Sintel trailer** by the Blender Foundation:

- Source: <https://download.blender.org/durian/trailer/sintel_trailer-480p.mp4>
  (SHA-256 `b670602fa00934ca27c4351bb0efe7ea7a07fae57284e44226025eeed7c51254`)
- Licence: [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/)
- Attribution: © copyright Blender Foundation | durian.blender.org
- Excerpt: 15 s to 45 s of the trailer's audio, decoded and resampled from 48 kHz AAC to 16-bit
  stereo 44.1 kHz with macOS `afconvert`. No other change.

The clip and its reference voices are not committed (about 16 MB together, like the voice models,
which are downloaded too). `ios/tools/separation_fixture.sh` rebuilds both into
`ios/.fixtures/separation/` (gitignored):

| File | SHA-256 (2026-11-25) |
|---|---|
| `clip.wav` | `833c2f32e7fa03f551953319d9dd86b3cde02abf92bc67fe532a17b5939b5bea` |
| `reference_voices.f32` (`ios/tools/reference_two_models.py`, onnxruntime 1.32.0 CPU) | `c9608b2b584571ef0dbf273163aa64721af19c24eaaebf0a83917626ab7e8cde` |
