#!/bin/sh
# Regenerates the DSP golden fixtures from the repo's UNCHANGED MusiclessDsp.java (US-003).
# Needs JDK 17+. Writes into MusiclessCore's test resources; commit the result.
#   ios/tools/dsp-golden/run.sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../.." && pwd)
dsp="$repo/smarttubetv/src/stmobile/java/com/newtube/mobile/player/MusiclessDsp.java"
out="$repo/ios/Packages/MusiclessCore/Tests/MusiclessCoreTests/Fixtures/dsp"
classes=$(mktemp -d "${TMPDIR:-/tmp}/dsp-golden.XXXXXX")
trap 'rm -rf "$classes"' EXIT

javac -d "$classes" "$dsp" "$here/DspGolden.java"
java -cp "$classes" com.newtube.mobile.player.DspGolden "$out"
printf 'MusiclessDsp.java sha256: %s\n' "$(shasum -a 256 "$dsp" | awk '{print $1}')"
