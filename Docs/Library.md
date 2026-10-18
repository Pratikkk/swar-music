# Music library

Add Folder imports a read-only folder reference, not copies of the audio files.
The sandbox entitlement allows user-selected read access and app-scoped bookmarks.
Bookmarks restore access on launch; stale bookmarks are refreshed. If access cannot
be restored, the app keeps the database records and asks the user to reconnect the
folder by removing and adding it again. Removing a folder deletes its index entries,
never its source files. Overlapping roots are rejected to avoid duplicate imports.
Playback holds an independent access token for its source folder.

## Storage and scanning

GRDB 7.11.1 manages `Application Support/Swar/Library.sqlite` in the app container.
Folders and tracks are persisted with schema migrations, foreign keys, browse indexes,
and an FTS5 index over title, artist, and album. Search words are quoted and bound as
query parameters. The UI starts with 500 tracks and offers Load More; grouping uses
currently loaded tracks, while search covers the entire database. Albums group by album artist and album title.

The scanner enumerates supported audio extensions recursively off the main actor,
skipping hidden files, packages, and symbolic links. Extensions select candidates;
the decoder probes file contents to identify the actual codec. Four workers inspect
metadata, and writes are batched. A lightweight fingerprint of file size, modification
time, adjacent cover state, and cached artwork skips unchanged files. Failed files
remain visible and are retried. Missing entries are reconciled only after a complete,
successful enumeration; inaccessible roots retain their stored tracks.

The scan entry point is explicitly nonisolated, with `@concurrent` on Swift 6.2+
to move the complete scan off the caller's actor even when caller-isolated async
defaults are enabled. Earlier Swift compilers use their existing nonisolated
async executor behavior. Enumeration retains its detached utility task and explicit
cancellation forwarding. Four structured inspection workers await a shared,
four-operation utility queue for blocking decode, metadata, and artwork work.
This prevents slow I/O from occupying cooperative executor threads. In-flight
operations finish before cancellation propagates and folder access is released;
only progress/model publication hops back to MainActor.

A main-actor regression test scans twelve real files through gated inspectors.
The main actor must resume to release the gates, inspection must stay off the
main thread, and active inspection must never exceed four workers. This test
also passed before the explicit executor annotation under the current package
defaults: the reported UI blocking was not reproduced in that configuration.
The app target's MainActor default does not itself annotate the package scanner.
The same responsiveness test also passed in a clean build with the Library
target's `NonisolatedNonsendingByDefault` feature enabled temporarily. The normal
package settings remain unchanged. The full suite passed 136 tests in 18 suites;
the device-monitor test was made independent of unrelated global-queue scheduling
while its simulated HAL probe is blocked.

Recursive FSEvents trigger a debounced incremental rescan. Scans also run at launch
and through Rescan. Changes arriving during a scan schedule another pass.

## Metadata and artwork

Each changed file first uses one bundled FFmpeg probe for source format, duration,
tags, and embedded artwork. If that probe fails (including missing, invalid, or
unloadable codec libraries), inspection tries the native decoder. A successful
native fallback supplies audio facts and duration without a track error; metadata
uses filename/folder defaults and external artwork when FFmpeg metadata is unavailable.
A track is marked unreadable only if both probes fail, with both diagnostics retained.
The healthy FFmpeg path still opens just one decoder. Playback retains its independent
native-first selection. The FFmpeg bridge reads stream and container tags across
ID3, MP4, Vorbis comments, and APE tags, avoiding a second tagging dependency.
Stored metadata includes title, artist, album artist, album,
genre, track/disc number, year, and available composer, comment, lyrics, compilation,
and ReplayGain tags. Tag availability depends on the source container and file.
Scanning checks whether a decoder can open the file; it is not a full-file integrity
check. Unreadable files retain an error row and cannot be played from the library.

Embedded covers take priority over `cover.jpg`, `folder.jpg`, and `front.png` beside
the audio file. ImageIO downsamples artwork to a maximum dimension of 384 pixels.
SHA-256 keys deduplicate PNG thumbnails under `Caches/Swar/Artwork` in the container.
Artwork cache failures do not mark otherwise playable audio as unreadable.

The single-probe inspection regression checks technical facts and duration against
the native decoder for PCM WAV, FLAC, ALAC, AIFF, and floating-point CAF, including
24-bit/192 kHz audio. Existing tagged-container and artwork tests cover both native
and bundled-only formats. This removes redundant decoder setup; no scan speedup
percentage has been measured. Unchanged files still skip inspection entirely.

Missing/invalid-library regressions cover WAV, FLAC, ALAC, MP3, AAC, AIFF, and CAF:
native source facts/duration remain intact, external covers are cached, and no false
track error is recorded. A scanner regression verifies retries clear a previously
stored codec error while corrupt audio and bundled-only WMA remain erroneous.
All 147 package tests pass, including the existing full tag/artwork checks with
healthy bundled codecs. Fallback metadata uses defaults rather than attempting a
second native tagging implementation.

## Playlists

Playlists are stored in `playlists` and `playlist_tracks` with foreign-key cascades linked to the
underlying tracks table. Creating, renaming, and deleting playlists update SQLite immediately.
Tracks added to playlists preserve insertion order via an explicit `position` column. Reordering,
track removal, and whole-playlist deletion update positions without leaving orphaned rows.
Duplicate tracks within the same playlist are supported via unique playlist item identifiers.

Playlists appear in the sidebar under their own section with a `+` creation button and context menus
for renaming and removal. Selecting a playlist opens `PlaylistDetailView`, showing track count, total
duration, artwork, and Play/Shuffle actions. Songs and albums throughout the library include an
"Add to Playlist" submenu in their context and action menus.

## Verification

Thirteen library tests cover incremental updates, deletion reconciliation, inaccessible
roots, symlink exclusion, literal search input, corrupt files, metadata across five
containers, embedded and folder covers, cache deduplication, bookmark restoration,
overlap rejection, nested FSEvents, paging/search across 50,001 stored tracks,
playlist creation, track ordering, reordering, removal, cascade deletion, model integration,
and automatic imports/metadata refresh/removal in a restored monitored folder.
The large test exercises the database, not a 50,000-file scan or UI frame-rate target.
Tests use temporary stores and original generated media in LibraryTests/Fixtures.
Regenerate those fixtures with `Tools/make_library_fixtures.py` and development ffmpeg.

The signed sandboxed Debug app was checked with a folder library, album artwork,
track browsing, artist search, duplicate-root rejection, and playlist creation and playback.
The standard suite skips hardware playback unless its explicit environment variables are set.

Library-only metadata editing and collection review are described in
[collection management](CollectionManagement.md). Writing embedded file tags,
playback history, and large-library UI performance profiling remain future work.

## Files settings

Swar → Settings… → Files (⌘,) and the library actions menu open the native settings
window. Settings and the library window share one LibraryModel, so adding a folder
starts the same bookmarked FSEvents watcher used by browsing. Folder selection uses
the sandboxed folder picker. Settings shows paths, monitoring status, per-folder
errors, scan progress, and last-check time, plus Add Folder and Rescan Now actions.
Removal asks for confirmation and removes indexed songs and playlist references;
the original files are untouched. Subfolders are included. Monitoring runs while
Swar is open, and launch rescans changes made while it was closed.

The signed app was checked by selecting an empty temporary folder in Files settings,
then copying a fixture into that folder. The shared library changed from 21 to 22
tracks automatically. The test source was removed afterward, preserving the user's
original music folder. The model regression also checks atomic file replacements,
deletion reconciliation, restored bookmarks/watchers, and watcher cleanup on removal.

## Artist browser

Artists groups the loaded library page by album artist, falling back to track artist
when album artist is empty. The artist list includes All Artists; selection filters
the album pane. Albums sort by name and songs by disc, track number, then title.
Artist thumbnails use local album artwork. Artist/album Play and Shuffle use the
existing playback queue; action menus support Play Next, Add to Queue, and existing
playlists. Song rows share the album detail controls, including current-track state.
The sidebar search filters the library; a missing selected artist resets to All Artists.
The existing loaded/total count and Load More control remain visible for paged libraries.

The signed Debug app was checked with All Artists, individual artist selection,
artist queue menus, and a narrow-window layout that stacks songs below album metadata.
The 80-test regression suite passes; the audio engine is unchanged by this UI update.

## Song menus and preferences

SongActions supplies the same ellipsis and right-click menu for Songs, Genres,
album details, Artists, and playlists. Add to Playlist can create a playlist when
none exists. Play Last appends to the existing queue. Get Info is read-only and
shows source metadata, bitrate, file size, modification time, and local path.
Copy writes the local file URL to the pasteboard; Show in Finder reveals it using
NSWorkspace. Playlist rows also retain their Move Up/Down and Remove from Playlist
commands. Streaming, store, station, dislike/recommendation, and file-writing Paste
commands are omitted.

Migration library-track-preferences-v4 adds a preferences table with favourite and
hidden flags, keyed to track IDs with cascade deletion. Metadata rescans preserve
these flags. Remove from Library confirms the action, hides the indexed row from
browsing/search, clears its favourites state, and removes its playlist references.
The original file and its scan fingerprint remain; automatic monitoring therefore
does not re-add it. Files settings can restore all excluded songs. Restoration does
not reconstruct previous playlist references. Removing a watched folder also clears
its track preferences. No audio-file deletion or tag-writing path is introduced.

Repository/model regressions verify preference persistence, metadata replacement,
search exclusion through rescans, playlist cleanup (including stale add requests),
restoration, and folder cleanup. The signed Debug app was checked with the menu,
Get Info, favourite toggling (then restored), and cancelling library removal. Copy
and Finder use native APIs; no clipboard changes or file deletion were needed for
that manual check.

## Watcher callback lifetime

The original context retain/release callbacks already gave FSEvents ownership of
the callback box; `passUnretained` alone was not evidence of a use-after-free.
[Apple documents stop → invalidate → release as the normal cleanup sequence](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html).
The following changes make application-side shutdown ordering explicit:

- Each watcher uses its own serial utility queue. The context never references the
  watcher or UI state directly.
- Deinit clears the client action under a lock. A callback that already obtained
  the action retains its captures through completion; later callbacks do no work.
  Captures are released outside the lock to allow reentrant destruction.
- Deinit asynchronously enqueues stop/invalidate/release on the callback queue,
  capturing immutable stream state and a strong callback reference. Cleanup runs
  behind the active callback, without blocking the UI or syncing onto the same
  queue when the action destroys its own watcher.
- Stream ownership is assigned only after Start succeeds. Creation/start failures
  have their own single cleanup path and cannot also run watcher deinit cleanup.

Already-enqueued MainActor work is still protected by LibraryModel's shutdown guard.
Validation: 150 tests passed across 20 suites. Three lifecycle tests cover a blocked
callback during watcher release, release from the callback itself, and capture
release without events; these also passed with Address Sanitizer using Swift
Testing (`swift test --sanitize address --disable-xctest --enable-swift-testing
--filter FolderWatcherLifetimeTests`). No original use-after-free was reproduced.
Universal release build 73 passed signing and bundled-codec checks.

## Renamed folder restoration (build 80)

Folder restoration persists the bookmark's resolved canonical path even when the
bookmark itself is not stale. Overlap detection uses connected canonical roots,
including correct root-directory prefix handling. Folder and track IDs remain
stable: renaming a watched folder and reopening Swar preserves favourites, edits
and playlist membership, while adding its new location again is rejected. The
regression uses a real temporary-folder rename and bookmark restoration. Existing
duplicate roots are not automatically merged or deleted by this change.
