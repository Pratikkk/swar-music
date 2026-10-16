# Listening-session restoration

The app saves the queue, current entry, position, cached duration/presentation,
shuffle/repeat settings, and the order to restore when Shuffle is turned off.
Duplicate tracks keep independent insertion IDs. Standalone files are saved as a
one-entry queue; a pending queue with no current song is also preserved.

Sessions live at `Application Support/Swar/PlaybackSession.json` in the app container.
Writes run on a serial utility queue, using atomic replacement. A checkpoint runs
every five seconds when state changes. Normal termination drains pending writes and
saves the final stable UI snapshot before closing audio and releasing file scopes.
Cleanup is idempotent. During an in-flight open/restore, quit retains the last stable
checkpoint rather than writing a mixture of old/new state. Unexpected termination
can lose changes since the last checkpoint; this is not a play-history database.

## Access and restoration

Read-only app-scoped bookmarks are deduplicated per source folder/file, with relative
track paths. Resolved URLs follow moved folders where macOS can find them. Stale
bookmarks are refreshed. Restoration uses `withoutUI` and never prompts for access.
Files whose bookmark cannot resolve remain in the queue with a reconnect message;
re-add their folder or reopen a file. Missing/corrupt audio is reported when opened,
and remains visible instead of disappearing from the saved queue. Failed Resume keeps
the cached position and presentation, so a later retry can continue from the same place.

Restoring does not open an audio device, change the device rate, or autoplay. Cached
song details and position appear with “Previous session · Ready to resume”. Resume
opens the current file, seeks to the saved position (clamped to the actual duration),
and starts playback. A position at EOF follows the engine's existing restart behavior.
Seeking before Resume only changes the saved target. Format/output claims appear
only after a real decoder/device session has opened. A queue without a current entry
shows “Queue Ready”, with Play enabled to start its first song.

Library startup and session loading run independently. A newly selected queue wins
over a late startup restore. Serialization/IO failures show a dismissible session
notice without overwriting playback errors. Corrupt/unsupported sessions are left
untouched until new listening activity replaces them. IDs, ordering, finite positions,
local URLs, relative paths, and a 64 MiB file-size bound are validated. Oversized
writes fail before replacing the previous file.

## Verification

Nine device-free tests cover exact queue/mode/presentation restoration, silent lazy
resume, saved-position seeking, final/idempotent saves, corrupt-file preservation and
replacement, unavailable files/bookmarks, moved folders, invalid versions/paths,
pending-queue Play, and protection of a newly selected queue.

A separate opt-in test uses real AUHAL with a quiet original ALAC fixture. It verifies
that loading a session leaves the device unopened and its rate unchanged, then checks
Resume at the saved position, actual 96 kHz output, and original-rate restoration:

```sh
python3 Tools/make_audio_fixtures.py /tmp/swar-queue-audio
SWAR_TEST_SESSION_FILE=/tmp/swar-queue-audio/quiet-24bit-96k.m4a \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path Packages/SwarKit --filter HardwareSessionTests
```

Run separately from other hardware tests. The full suite has 67 tests; hardware tests
are skipped unless their explicit environment variables are set. The signed Release
build is verified; the new Resume banner has not been manually checked in a restarted
sandboxed UI. The existing paused preview is preserved until the user restarts it.
