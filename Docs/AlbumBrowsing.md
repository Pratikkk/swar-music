# Album browsing

Albums and Recently Added now use an independent album browser backed by SQLite
summaries across the full visible library, rather than grouping the first 500
loaded songs. Search uses the existing literal prefix search and field selector.
A matching song selects its complete album; counts, details, Play/Shuffle, queue,
and playlist actions include all visible tracks in disc/track order. Hidden songs
never produce matches and unreadable songs remain visible but are skipped during
playback and queue actions. Album identity includes album artist and title.

The browser provides:

- Inline Sort controls and saved All Albums / Lossless / Missing Artwork filters.
  Lossless includes albums whose visible tracks all report a lossless source;
  mixed-format albums remain intact in All Albums. Missing Artwork uses the
  indexed artwork key. Counts reflect complete albums after filtering.

- Artwork-size slider, saved between launches, with responsive grid columns.
- Two-line titles, artist, release year, and song counts.
- Title, artist, release-year (newest first), and recently-added sorting, plus
  Reverse Order in the header view-options menu. Preferences persist.
- Right-click actions for Open, Play, Shuffle, Play Next/Last, and Add to Playlist.
- A grid that stays mounted beneath album details, preserving the browsing position
  on Back. Search resets selection and position.
- Direct Home-to-album navigation without leaving a search filter behind.
- Monthly Recently Added grouping and in-content clearance for the floating player.
- Loading, retry, empty/search-empty, scan-progress, and library-error states.

Only loaded-page summaries are held for the collection. Tracks for a selected album or action
are fetched on demand. Album reloads start immediately, without an artificial
delay; cancelled and outdated results are discarded.
Playback position updates do not trigger album metadata queries. The browser does
not introduce polling timers or load every song into view state.

Sorting is performed by SQLite ORDER BY in the repository query, using GRDB’s
localized natural collation for titles and artists, aggregate year/date expressions,
and binary identity tie breakers. Reverse changes every ordering direction. Only
enum-selected SQL expressions are interpolated; search values remain bound.
Recently Added always requests newest-first order. Sort changes reload summaries;
there is no second Swift sort or reverse pass. Whole-album filters and total counts
are computed in SQL before pagination; calendar-month grouping remains on a
dedicated serial actor. Results are retained until replacement
and cancelled results are ignored. Group lookup uses month keys instead of repeated
section searches. Unchanged summaries do not trigger another arrangement. Direct
Home/context-menu navigation reuses the active metadata load instead of starting
a second query, resets the album filter, and opens the complete album.

Compact artwork uses smaller 256-pixel thumbnails; default and large grids use
384 and 512 respectively, sharing the bounded cover cache. Sort/filter changes
return to the top, while opening an album and Back retain the grid position.
Database queries queued after cancellation skip their work. Scanning's blocking
inspection uses a separate operation queue with four workers so slow file reads
do not occupy Swift's cooperative executor; folder access stays retained until
in-flight work finishes, including cancellation. No GitHub DMG build is triggered
by these changes.

The package suite covers SQL natural sorting and stable ties, all reverse orders,
years/recent dates, search and hidden-song behavior, calendar boundaries, whole-album quality filtering, missing artwork,
10,000-album arrangements, cancellation, and the existing complete-album search
and background-scan responsiveness checks. These checks do not establish a measured
scrolling FPS or CPU/battery improvement.

Native dark-mode checks verified the Lossless filter's complete three-song
Kalank album, Missing Artwork's empty state and reset, release-year ordering,
searching “Nahi” and opening all 19 Balgandharva songs, Home navigation outside
an active filter, Recently Added month grouping, and compact artwork resizing.
Opening Paap at the bottom and returning preserved scroll position (1.0).
Playback stayed paused at its saved position and device volume was preserved.

## Validation

- 103 Swift package tests passed across 13 suites.
- Repository tests cover albums beyond the initial 500 songs, partial song matches
  returning complete counts, field scopes, malformed search, hidden matches,
  duplicate titles by different artists, unreadable tracks, artwork/year/duration,
  full track retrieval, and removed folders.
- Debug build succeeded. Native light-appearance checks covered wide/compact grids,
  artwork sizing, release-year ordering, context-menu options, monthly grouping,
  and preserved scroll position after opening/back.
- Searching “Nahi” found the complete 19-track Balgandharva album. Home artwork
  opened Kalank directly with all three tracks and no residual search query.
- Saved playback position and device volume were preserved. No new audio-output
  hardware measurements or separate dark-appearance visual pass were performed.

SQL sorting validation: 140 tests passed across 19 suites. Local universal build 66
passed signature and bundled-codec checks. Native checks confirmed artist order,
newest/oldest release-year order, and restoring the saved Artist preference.

## Pagination

Albums and Recently Added initially request 200 summaries using bound SQL LIMIT
and OFFSET. Scrolling to the footer requests the next batch; overlapping requests
are suppressed. The repository clamps limits to 1…500 and offsets to zero or
higher. Filters run on complete aggregated albums before the page limit. Header
album/song counts cover all matching albums, not just the loaded batch. Initial
counts and rows share one database read; subsequent pages do not recount totals.

Search, scope, sort, reverse, filter, and library revisions reset pagination.
Existing cards stay visible while replacement results load; request keys and
generations reject stale results. Additional-page failures preserve loaded cards
and offer an inline retry. A library revision reloads from offset zero; duplicate
card identities are suppressed if a scan changes rows before its revision arrives.
Monthly sections merge across loaded pages. Going Back retains loaded pages and
scroll position. Exact album lookup lets Home/context-menu navigation open an
album outside the loaded pages without loading intervening summaries.

Pagination regression tests use 513 two-song albums: complete/partial/empty pages,
clamped limits/offsets, all sort modes and their reverse across boundaries,
whole-album search/filter semantics, full totals, missing artwork, hidden albums,
and exact lookup beyond the first page. Loaded cards accumulate as the user scrolls;
this bounds initial loading, rather than imposing a fixed cap on all visited pages.

Validation: 141 package tests passed in 19 suites. The 513-album pagination test
also passed after adding presentation-total assertions. Universal local build 68
passed signature and bundled-codec checks and was installed. Native checks on the
13-album library covered full counts, Lossless, missing-artwork empty/reset states,
Home-to-Ghar navigation outside an active filter, and Recently Added month grouping.
Playback remained paused at its saved position. Multi-page boundaries are covered
by automated repository tests; the native library fits within one 200-album page.
