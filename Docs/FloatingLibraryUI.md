# Floating library interface

The reference-inspired library uses a neutral translucent sidebar, a compact
left-aligned section title, search and view options at the top right, and an
artwork grid with a floating material playback bar at the bottom. It follows
macOS appearance and uses native vibrancy rather than a simulated background blur.
Radio, streaming accounts, and video sections are omitted for the local audio app.

Albums opens its grid by default. Cards have aligned single-line titles and artist
captions; the playback button appears on hover, keyboard focus, and the current
album. Clicking the current album's playback button toggles playback. Cover and
title buttons open the existing album details. View options persist sorting by
album title, artist, or recently added, with deterministic tie-breaking.

Search works through the sidebar Search action or ⌘F. Escape clears its query.
The same top-right field filters each library section. The sidebar retains Home,
Recently Added, Artists, Albums, Songs, Genres, playlist management, music folders,
and Settings. Keyboard arrows navigate sidebar destinations while it has focus.

The floating player retains fixed transport widths, artwork, track details, seek,
shuffle/repeat, device volume, and Up Next. Its measured height reserves bottom
space in the content so final rows and footers stay reachable, including when an
error or restoration notice makes the player taller. It uses the existing guarded
playback actions and native system media integration.

Visual/manual checks in the running app covered the dark appearance, wide and
narrow layouts, grid/detail navigation, title sorting, ⌘F search and Escape reset,
the last Songs rows, the Up Next popover, and playback/pause from the floating bar.
Light appearance follows semantic system colors and materials; a separate visual
light-mode pass was not performed.

## Follow-up polish

Artist selection uses inset rounded highlights with a pink label, matching the main navigation. Artist album headings reserve a 26-point format badge slot so starting playback does not shift song rows. Songs and Genres stack duration above codec/sample rate, leaving more horizontal room for titles.

Playlist playback and queue actions are disabled independently of management actions: empty playlists can still be renamed or deleted. Loading displays progress instead of a premature empty state. Playlist identity isolates local state on selection changes, and cancellation plus a generation token prevents older asynchronous reloads from publishing over newer results.

Validation: 92 package tests passed and the Debug app built successfully. Manual checks covered artist selection, the empty-playlist options menu and Rename dialog, cleanup of the temporary test playlist, and Songs at 1100- and 792-point window widths in dark appearance. Light appearance was not separately inspected in this pass.

## Floating player scrolling

The detail viewport now extends to the window bottom. The player overlays it without reserving a rectangular bottom strip; rows and artwork scroll behind its glass capsule. Library counts and Load More remain above the content. Bottom clearance is part of the scrolling content, sized from the actual player height (including notices). Scroll views use trailing content padding; Songs and Genres use a hidden trailing spacer row because macOS List does not reliably apply scroll-content margins. This lets the final song scroll entirely above the controls.

Validation: Debug build succeeded. In the app's light appearance, Songs scrolled beneath the player, and the final song and its options were fully visible above it at the bottom of the list.
