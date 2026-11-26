#!/bin/sh
# Builds the end-to-end separation fixture for US-005 in ios/.fixtures/separation (gitignored):
#   clip.wav               30 s of the Sintel trailer (CC BY 3.0, Blender Foundation), 16-bit stereo 44.1 kHz
#   reference_voices.f32   reference_two_models.py's voices for it (interleaved little-endian float32)
# Licence and provenance: Packages/MusiclessCore/Tests/MusiclessCoreTests/Fixtures/separation/LICENSE.md.
# Needs the models in ios/.models (MUSICLESS_LIVE_MODELS=1 swift test ... --filter liveRelease) and
# Python 3 with numpy and onnxruntime (the script makes a venv in ios/.vendor/venv if needed).
set -eu

SOURCE_URL=https://download.blender.org/durian/trailer/sintel_trailer-480p.mp4
SOURCE_SHA256=b670602fa00934ca27c4351bb0efe7ea7a07fae57284e44226025eeed7c51254
START_SECONDS=15
SECONDS_LONG=30

ios=$(cd "$(dirname "$0")/.." && pwd)
cache="$ios/.vendor/cache"
out="$ios/.fixtures/separation"
venv="$ios/.vendor/venv"
mkdir -p "$cache" "$out"

source="$cache/sintel_trailer-480p.mp4"
if [ ! -f "$source" ] || [ "$(shasum -a 256 "$source" | awk '{print $1}')" != "$SOURCE_SHA256" ]; then
  curl -fL --retry 3 -o "$source.part" "$SOURCE_URL"
  mv "$source.part" "$source"
fi
[ "$(shasum -a 256 "$source" | awk '{print $1}')" = "$SOURCE_SHA256" ] \
  || { rm -f "$source"; echo "separation_fixture: SHA-256 mismatch for the trailer" >&2; exit 1; }

if [ ! -x "$venv/bin/python" ]; then
  python3 -m venv "$venv"
  "$venv/bin/pip" install -q "onnxruntime==1.32.0" numpy
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/separation.XXXXXX")
trap 'rm -rf "$work"' EXIT
# The trailer's AAC is 48 kHz; afconvert (Core Audio) decodes and resamples it once, and both the
# Swift test and the Python reference read the same 16-bit result.
afconvert -f WAVE -d LEI16@44100 -c 2 "$source" "$work/full.wav"

"$venv/bin/python" - "$work/full.wav" "$out/clip.wav" "$START_SECONDS" "$SECONDS_LONG" <<'EOF'
import struct, sys, wave
source, target, start, length = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
# afconvert writes WAVE_FORMAT_EXTENSIBLE, which the wave module can't read: walk the RIFF chunks.
data = open(source, "rb").read()
assert data[:4] == b"RIFF" and data[8:12] == b"WAVE"
at, pcm, fmt = 12, None, None
while at + 8 <= len(data):
    tag, size = data[at:at + 4], struct.unpack("<I", data[at + 4:at + 8])[0]
    if tag == b"fmt ":
        fmt = struct.unpack("<HHIIHH", data[at + 8:at + 24])
    if tag == b"data":
        pcm = data[at + 8:at + 8 + size]
    at += 8 + size + (size & 1)
channels, rate, bits = fmt[1], fmt[2], fmt[5]
assert (channels, rate, bits) == (2, 44100, 16), fmt
frames = pcm[start * 44100 * 4:(start + length) * 44100 * 4]
assert len(frames) == length * 44100 * 4
with wave.open(target, "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(44100); w.writeframes(frames)
EOF

"$venv/bin/python" "$ios/tools/reference_two_models.py" "$ios/.models" "$out/clip.wav" "$out/reference_voices.f32"
(cd "$out" && shasum -a 256 clip.wav reference_voices.f32)
