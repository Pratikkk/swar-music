# Album browsing

Albums and Recently Added now use an independent album browser backed by SQLite
summaries across the full visible library, rather than grouping the first 500
loaded songs. Search uses the existing literal prefix search and field selector.
A matching song selects its complete album; counts, details, Play/Shuffle, queue,
and playlist actions include all visible tracks in disc/track order. Hidden songs
never produce matches and unreadable songs remain visible but are skipped during
playback and queue actions. Album identity includes album artist and title.

The browser provides:

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

Only summaries are held for the collection. Tracks for a selected album or action
are fetched on demand. Search queries debounce and discard cancelled results.
Playback position updates do not trigger album metadata queries. The browser does
not introduce polling timers or load every song into view state.

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
