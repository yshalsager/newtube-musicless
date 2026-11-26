# Browse fixtures

`/youtubei/v1/search` answers for the TV client (TVHTML5 7.x, AppClient.TV), recorded from the Mac
on 2026-11-26 with no visitor and no cookie, then scrubbed: `responseContext`, tracking and logging
fields, `visitorData` and the onesie `initplayback` URLs are removed (they carry googlevideo node
names). `BrowseParserTests` reads them; `fixturesCarryNoAddressOrVisitor` re-checks them.

- `search_bbb.json`: "big buck bunny", one results shelf of 20 videos with a continuation.
- `search_bbb_continuation.json`: that continuation's answer (`continuationContents.sectionListContinuation`).
- `search_channel_shorts_cluster.json`: "mrbeast": results with channel lockups, a Shorts shelf and
  a `clusterShelfRenderer` (Android drops the cluster: only shelves become sections).
- `next_bbb.json`: `/next` for Big Buck Bunny (TV client): `videoMetadataRenderer` (title, views, date,
  owner), the description engagement panel, the comments panel, and the related `pivot` (10 grid
  shelves of 3 `tileRenderer`s, with a list-level continuation).
- `next_bbb_continuation.json`: that continuation (11 more shelves, no further page).
- `channel_blender.json`: `/browse` for the Blender channel (`tvSurfaceContentRenderer`: the
  `channelHeaderRenderer` and 15 titled shelves; trimmed to 6 items per shelf, its buttons, topbar,
  panels and framework updates removed).
- `channel_blender_videos_continuation.json`: the Videos shelf's next page (`horizontalListContinuation`).
- `playlist_open_movies.json`: `/browse` for `VLPL6B3937A5D230E335` (`twoColumnRenderer`:
  `entityMetadataRenderer` and `playlistVideoListRenderer`).
- `home_signed_out.json`: `/browse` `default` (Home) without an account: a search bar only. Its
  `feedbackToken`s read `scrubbed` (a secret scanner flagged the real ones as an API key).
- `comments_bbb.json`: the comments panel's first page (`/next` with its token): an
  `itemSectionContinuation` of `commentThreadRenderer`s and a next token. Trimmed to 5; authors,
  avatars and texts replaced (`@commenterN`, `Comment text N`).
- `comments_bbb_replies.json`: the first comment's replies (its `detailViewEndpoint` token): the
  parent `commentRenderer` first, then replies. Trimmed and scrubbed the same way.
