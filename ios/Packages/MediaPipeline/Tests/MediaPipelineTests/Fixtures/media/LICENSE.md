# Media fixtures: licence and provenance

Byte ranges of **Big Buck Bunny** (2008) by the Blender Foundation, as YouTube serves it
(video `aqz-KE-bpKQ`, the Blender Foundation's official upload), recorded on the iPhone on 2026-11-25
with the app's `--record-media` debug run (MediaFetcher, Range requests):

- Licence: [Creative Commons Attribution 3.0](https://creativecommons.org/licenses/by/3.0/)
- Attribution: (c) copyright 2008, Blender Foundation / www.bigbuckbunny.org

| Files | Content |
|---|---|
| `140-*` | itag 140, AAC-LC 44.1 kHz stereo (`audio/mp4; codecs="mp4a.40.2"`): init range, index range (sidx), first two segments |
| `160-*` | itag 160, H.264 144p (`video/mp4; codecs="avc1.4D400C"`): the same |
| `manifest.json` | each file's itag, MIME type, content length, init and index ranges, and the two segments' byte ranges and times |

Only media bytes and byte ranges: no URL, visitor id or address was stored.
