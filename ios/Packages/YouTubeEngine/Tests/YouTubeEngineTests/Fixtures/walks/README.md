# Walk replay fixture

`device_walks.json` is MediaServiceCore's `youtubeapi/src/test/resources/walk_replay/device_walks.json`
at `902e4d17` (2026-09-29), copied unchanged: every `/player` walk the Android app made on a Pixel
and an emulator for 22 cases (the clients asked, each answer's status, reason, deliveries and
flags, and what the walk did), built from device logs by `tools/netbench/appbench/replay_fixtures.py`
in the main repo. Android's `VideoInfoReplayTest` replays it through its walk; `WalkReplayTests`
replays the signed-out walks through `SourceWalker`.

It holds video ids and YouTube's refusal texts, no visitor ids, addresses or tokens.
