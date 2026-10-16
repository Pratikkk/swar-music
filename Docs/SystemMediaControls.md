# System media controls

Start a song in Swar to make it available to macOS Now Playing. The app registers
native MediaPlayer commands for Play, Pause, Toggle Play/Pause, Next, Previous,
and Change Playback Position. macOS routes keyboard and compatible headphone
controls to the currently selected media app; Swar needs no global keyboard hook
or Input Monitoring permission.

Control Center receives the current title, artist, album, artwork, duration,
elapsed time, playback rate, and paused/playing state. A restored paused session
does not publish itself until actual playback begins, avoiding taking over from
another player merely because Swar launched. After playback begins, pausing retains
the track and stopping the app removes its command handlers and Now Playing data.

Remote commands use the same Player actions as the app. Explicit Play and Pause
are idempotent; unavailable queue navigation and conflicting busy-state actions
are rejected, and invalid seek values are rejected while valid positions clamp to
the song duration. The OS advances elapsed time itself; ordinary playback ticks do
not rewrite the Now Playing dictionary. Seeks, pauses, song changes, and completed
artwork loads do update it.

Artwork is decoded off the main actor to a maximum of 512 pixels. Cancelled or
superseded loads cannot attach old artwork to a newer song. MediaPlayer artwork
providers and command callbacks are explicitly nonisolated/Sendable: the system
invokes them on its own queues, which otherwise triggers Swift 6 actor checks.
Artist and album metadata remain optional in saved queue entries, preserving
compatibility with existing sessions.

Validation: 92 package tests passed, including remote command routing, repeated
Play/Pause, queue boundaries, invalid seeks, busy-state rejection, shutdown,
timeline extrapolation, old session decoding, and a background-thread artwork
request. Debug playback with artwork ran and paused successfully after correcting
a background callback isolation crash discovered in the smoke test. The UI
automation tool cannot synthesize macOS hardware media keys, so physical keyboard
and headphone button routing, and visual Control Center verification, remain
manual checks on the installed build.
