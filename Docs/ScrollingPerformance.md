# Scrolling and artwork updates

Album presentation is built when album data or sort settings change. Scrolling no longer writes a visible-album binding that re-evaluates sorting and month grouping. The grid remains mounted behind details, so Back retains its native scroll position. Search and sort changes explicitly return to the top.

Artist and album grouping is materialized when the track snapshot changes, including metadata edits and rescans. Selecting an artist, updating playback state or scrolling does not regroup the library. Artist sections and song stacks create content lazily.

Artwork has a synchronous, thread-safe NSCache lookup for warm cells. A hit appears immediately without a placeholder/actor round trip. Cache misses decode on a serial utility actor; requests waiting behind other work recheck cancellation and the cache. This bounds simultaneous decode work and avoids duplicate decoding for visible cells sharing artwork. Source images are unchanged.

Song, management, queue and floating-player artwork use 128-pixel thumbnails. Album cards retain 384-pixel thumbnails. A square 128-pixel image has one ninth the pixels of a 384-pixel image. Cache keys include the requested size; the shared cache remains limited to 256 entries / 32 MiB of decoded cost. Visible views may also retain their displayed bitmap. Cache limits are eviction hints, not a whole-process memory limit. Placeholder gradients are only rendered when artwork is unavailable; redundant clipping and non-crossfading image identities are removed.

The floating player's seek slider observes the playback clock in its own view, isolating that frequent update from the glass bar, title, artwork and transport buttons. A pending drag is cancelled if the current song changes.

Validation: Debug compilation and 115 Swift tests in 14 suites pass, including size-specific thumbnails, warm cache access after the source disappears, shared concurrent requests, cancellation, and invalid/remote artwork rejection. These are functional/resource checks, not a measured frame-rate guarantee. Hardware audio behavior is unchanged.

## Background browsing preparation (build 79)

Artists now groups and naturally sorts its track snapshot on ArtistBrowseArranger,
an independent actor, rather than inside the main-actor view's change handler.
Prepared albums retain stable row IDs, disc boundaries, artwork selection and
rounded duration summaries. Playback-state changes do not redo this work, and
cancelled preparation cannot replace a newer view snapshot.

Playlists prepare filtered rows on PlaylistBrowseArranger. Original row numbers,
alternating backgrounds, playable order, cover selection and duration are prepared
once per changed source/query. Rendering no longer refilters the playlist, sums
all durations, or linearly searches the entire playlist for each row's index.
A small revision/query key makes row availability checks constant-sized. Search
changes debounce for 150 ms and retain the displayed rows while a new snapshot
is prepared; actions on stale search results are disabled. Data-only refreshes
have no debounce. Unchanged SQL snapshots skip preparation. Manual playlists also
observe membership timestamps and completed scans, fixing stale open views.

A per-playlist TrackSearchDocument index reuses Unicode tokenization across query
changes. Each distinct word is stored once per song with a field mask, preserving
artist/album-artist matching, Latin accent folding, non-Latin vowel marks, and
literal prefix-search behavior. The index is rebuilt after source metadata changes,
is owned by the playlist view's preparation actor, and is released with that view.
Cancellation is checked during preparation and filtering. This trades one retained
search index for eliminating repeated tokenization and temporary arrays.

The shared song-page loader now uses one cancellable request for section, search,
field and sort changes. Album, collection and playlist screens do not additionally
query an unused 500-song page. Cancelled queued song/collection reads exit before
SQL work, and cancelled model reloads do not publish an error. Manage Library's
fixed 200 ms delay is removed for filters and pagination; only search text changes
have a 150 ms debounce. Generation/context guards reject stale results.

Small playlist-row and Home-favourite artwork now request 128 pixels instead of
384, matching other small song/queue cells. A 128-pixel square has one ninth the
pixel count of a 384-pixel square; this is a decoded-image cost reduction for those
cells, not a claim about whole-app memory usage.

Validation: 163 tests in 22 suites pass. New regressions cover artist/disc ordering,
compilation grouping, duplicate playlist membership, original row numbering,
filtered alternation, unreadable songs, metadata/artwork changes, cancellation,
and indexed/direct search equivalence across all fields including Devanagari.
An opt-in Release benchmark on 10,000 synthetic songs measured six former filter
passes at 9.555 s, an initial indexed snapshot at 1.631 s, and a subsequent different
query at 1.589 ms (209 and 11 matches respectively). These compare different amounts
of preparation work, not equivalent end-to-end UI frame times. Initial indexing
still has a CPU/memory cost, performed off the main actor. Reproduce with:

```sh
SWAR_BROWSE_BENCHMARK=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --configuration release --package-path Packages/SwarKit --filter BrowsePreparationTests
```

Universal build 79 passed signing and bundled-codec decode/seek/EOF checks and was
installed. Native UI checks covered artist scrolling, indexed Smart Playlist
search and clearing, song-page search after loader consolidation, and switching
Manage Library filters. The app was returned to Recently Added with search empty;
the paused 3.088-second position and output volume were preserved. These checks
confirm behavior and rendering, not a measured scrolling FPS improvement.
