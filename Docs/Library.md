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

Recursive FSEvents trigger a debounced incremental rescan. Scans also run at launch
and through Rescan. Changes arriving during a scan schedule another pass.

## Metadata and artwork

Technical metadata comes from the decoder. The bundled FFmpeg bridge reads stream
and container tags across ID3, MP4, Vorbis comments, and APE tags, avoiding a second
tagging dependency. Stored metadata includes title, artist, album artist, album,
genre, track/disc number, year, and available composer, comment, lyrics, compilation,
and ReplayGain tags. Tag availability depends on the source container and file.
Scanning checks whether a decoder can open the file; it is not a full-file integrity
check. Unreadable files retain an error row and cannot be played from the library.

Embedded covers take priority over `cover.jpg`, `folder.jpg`, and `front.png` beside
the audio file. ImageIO downsamples artwork to a maximum dimension of 384 pixels.
SHA-256 keys deduplicate PNG thumbnails under `Caches/Swar/Artwork` in the container.
Artwork cache failures do not mark otherwise playable audio as unreadable.

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

Playback history, tag editing, advanced sorting, and
large-library UI performance profiling remain future work.

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
