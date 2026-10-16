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

## Verification

Seven library tests cover incremental updates, deletion reconciliation, inaccessible
roots, symlink exclusion, literal search input, corrupt files, metadata across five
containers, embedded and folder covers, cache deduplication, bookmark restoration,
overlap rejection, nested FSEvents, and paging/search across 50,001 stored tracks.
The large test exercises the database, not a 50,000-file scan or UI frame-rate target.
Tests use temporary stores and original generated media in LibraryTests/Fixtures.
Regenerate those fixtures with `Tools/make_library_fixtures.py` and development ffmpeg.

The signed sandboxed Debug app was checked with a folder library, album artwork,
track browsing, artist search, and duplicate-root rejection. The standard suite
skips hardware playback unless its explicit environment variables are set.

Queue management, playlists, playback history, tag editing, advanced sorting, and
large-library UI performance profiling remain future work.
