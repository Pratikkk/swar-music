# Swar identity and Home

Swar uses an appearance-aware violet accent, warm light canvas, dark surfaces,
and serif display headings on Home. The native translucent sidebar and floating
material player remain. The sidebar shares Home's serif Swar heading and violet
“स्व” monogram, with rounded violet selection, subtle hover feedback, a Search
shortcut hint, spaced section labels, folder-monitoring indicators, and an anchored
local-library/settings card. Its navigation scrolls independently at compact heights;
keyboard navigation, playlist actions, and folder context menus remain available. Playback buttons use a deep violet fill with white symbols.

Home is the default landing screen. It contains library-wide song, album, and
lossless counts; a restored/current song with Resume/Pause; favourite song
shortcuts; up to eight distinct recent albums; and watched-folder status with
links to folder settings. Album artwork opens that album directly in the album browser. Its overlay Play button loads the full album in disc/track order, including
songs outside the library's initial page. Hidden songs are excluded, unreadable
songs are skipped, and albums without playable songs have disabled Play buttons.
Searching Home uses the existing song search; clearing the query returns Home.

The overview is read from SQLite in one transaction, independently of the current
search and page. It refreshes after library changes and scans, without a polling
timer. Artwork uses the existing bounded thumbnail cache. The scroll content
retains clearance for the floating player.

Format-chip details now separate Source, Playback path, Output, and verification.
Matching formats still do not prove unchanged samples. A restored session can
show source metadata without opening audio hardware; inactive output remains
unavailable and unverified. This fallback source lookup covers loaded library
tracks; other restored files retain the saved-place message until playback.

## Validation

- Swift package: 103 tests across 13 suites passed.
- Debug macOS app built successfully under Swift 6.
- New repository coverage checks counts, hidden tracks, favourites, distinct recent
  albums, and full album retrieval with 601 records, beyond the first 500 songs.
- Manual light-appearance checks at compact and wide window sizes verified Home,
  navigation to favourites/albums, and scrolling clear of the floating player.
- Accessibility inspection verified the three signal-path stages and inactive
  output explanation. Window screenshots did not capture the separate popover.
- Sidebar checks covered wide/compact layouts, scrolling, selected states, arrow-key
  navigation, and ⌘F search focus.
- Restored song, position, queue, and output volume were preserved. No new physical
  output-integrity measurement or separate dark-appearance visual pass was done.
