#!/bin/sh
# Fixture for ChallengeSolverTests (US-016): the current TV player JS (the one the app reads from
# youtube.com/tv) and Node's answers to fixed challenges, in the gitignored ios/.fixtures/solver.
# Needs network and node. Re-run when YouTube ships a new player.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out="$here/../.fixtures/solver"
mkdir -p "$out"
ua='Mozilla/5.0 (Linux armeabi-v7a; Android 7.1.2; Fire OS 6.0) Cobalt/22.lts.3.306369-gold (unlike Gecko) v8/8.8.278.8-jit gles Starboard/13, Amazon_ATV_mediatek8695_2019/NS6294 (Amazon, AFTMM, Wireless) com.amazon.firetv.youtube/22.3.r2.v66.0'
player=$(curl -fsS -A "$ua" -H 'Cookie: SOCS=CAISEwgDEgk5NTA1MzE4OTQaAmVuIAEaBgiA7frSBg' https://www.youtube.com/tv \
  | grep -o '"player_url":"[^"]*"' | head -1 | sed 's/"player_url":"//; s/"$//; s#\\/#/#g')
case "$player" in /*) player="https://www.youtube.com$player" ;; esac
echo "player: $player"
curl -fsS "$player" -o "$out/player.js"
echo "$player" > "$out/player-url.txt"
node "$here/solver-oracle/oracle.mjs" "$here/../Packages/YouTubeEngine/Sources/YouTubeEngine/JS/nsigsolver" "$out"
