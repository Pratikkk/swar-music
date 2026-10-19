# Playlist import and export

Choose **Import Playlist…** from the sidebar playlist + menu or the view/library
options menu. Select an M3U/M3U8 file, review matched/unmatched entries and the name,
then import. Matching uses exact local file paths against the full visible library,
independently of the current search or loaded page. Relative paths resolve against
the playlist folder; folder aliases resolve before matching. Order and duplicate
entries are preserved. Unmatched, hidden and unsupported entries are skipped after
review. Import does not add music folders, copy music or play songs automatically.
An empty/no-match import cannot create a playlist. Changes to matched library records
between review and save fail the transaction without leaving a partial playlist.

Choose **Export Playlist…** from a playlist's options or sidebar context menu. Export
includes the whole playlist even when the current screen is filtered by search.
Smart Playlists export their current song membership; rules are not portable M3U
content. Both output formats are UTF-8; M3U8 is the default. The native Save dialog
selects the destination and handles replacement confirmation. Music files are not
copied. Absolute paths are the default; relative paths are optional and resolve
against the export destination. Move the playlist and music folders together to
retain relative links. Disconnected music roots must be reconnected before export.

M3U8 input must be UTF-8 (an initial BOM is accepted). M3U input also accepts legacy
Windows-1252 text. CRLF/LF and ordinary comments/EXTINF are supported. Local file URIs
are accepted; remote URLs and Windows drive/UNC paths are unsupported on macOS and
are never fetched. HLS streaming playlists are rejected. Imports/exports are bounded
to 8 MB and 100,000 entries; imported path lines are bounded to 16 KB. File names
containing line breaks cannot be exported. Metadata newlines are flattened so tags
cannot inject playlist entries. File reading/writing and path preparation run off
the UI actor; export writes atomically to the chosen destination.

## Current permission gate

The code builds and 202 tests pass, including Unicode/duplicate order, relative and
absolute round trips, legacy encoding, bounded parsing, alias resolution, unsupported
streams, hidden/missing matches, stale-import rollback, persistence and original
music/file preservation. The application's existing user-selected **read-only**
entitlement remains unchanged. Automatic approval review rejected broadening it to
user-selected read/write without explicit owner approval. Native export saving and
final installation are pending that approval. Watched-folder bookmarks continue
to request read-only access even if selected-file export writing is later approved.

Native UI preview of the unchanged-permission build verified the M3U8 file picker,
a review with two matched duplicate entries plus two unmatched/unsupported entries,
cancellation without creating a playlist, and a Smart Playlist export preview with
three current songs. No export destination was saved from the sandboxed app. The
previous installed build and Listening screen were restored after the preview.
