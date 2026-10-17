# Collection management

Manage Library in the sidebar provides collection-wide maintenance, independent of
the Songs page, current search result page, or album browser. The page shows song
and album totals, indexed file size and duration, monitored-folder status, and six
review filters: All Songs, Incomplete Details, Missing Artwork, Possible Duplicates,
Unreadable, and Removed. Counts describe the collection; search narrows the selected
review list. Rows load in pages of 200, with Load More. Small windows use a filter
menu to leave room for the native selection table.

## Review semantics

- Incomplete Details identifies missing core title/artist/album tags, invalid or
  absent original tag data, or missing displayed title/artist/album. Valid local
  corrections supersede missing original tags. Optional genre/year tags are not
  required, and decoder-error rows have a separate review filter.
- Missing Artwork means no indexed artwork key; it does not inspect cached files
  for damage or download artwork. Choose Artwork… to assign a cover locally; see
  [artwork editing](ArtworkEditing.md).
- Possible Duplicates compares case-folded (SQLite lower), trimmed title/artist and
  duration rounded to a second, excluding unreadable/unknown-artist/nonpositive
  duration entries. These are candidates, not byte-identical duplicates. No song is
  removed automatically. Different releases or formats can legitimately match.
- Unreadable shows stored decoder/scanner errors. Folder-access failures appear in
  folder status and settings. Files deleted from disk are still reconciled out by
  the existing scanner; there is no missing-file relocation workflow yet.
- Removed reviews hidden songs and supports restoring a chosen subset. Restoring
  visibility does not recreate previous playlist membership or favourites.

Select one song to edit details, or multiple songs for playlist creation/addition
and removal. Removal asks for confirmation, operates in one database transaction,
leaves files in place, removes playlist references, and keeps songs hidden across
scans. Show in Finder is available from the row context menu. Selection is cleared
when search/filter changes, and stale results cannot be acted on during a switch.

## Library-only metadata

Edit Details is also available in song action menus. It changes title, artist,
album artist, album, genre, year, track number, and disc number in Swar. No audio
file or embedded tag is written. The sheet explains that distinction.

Migration library-metadata-v6 adds a foreign-keyed overrides table. Edits update the
existing track row and FTS index transactionally, preserving the stable track ID,
scan fingerprint, favourites and playlist references. When a changed file is
rescanned, its fresh original metadata is stored before local corrections are
reapplied. Reset to File Details removes corrections and restores the latest
scanned original fields without replacing technical metadata. Removing a file's
track record cascades its corrections. Current queued entries keep their existing
presentation; newly queued entries use the corrected library details.

## Verification

- 106 tests in 13 suites passed; Debug macOS build succeeded.
- Added coverage for review across 601 songs, paging, malformed/scoped search,
  duplicate candidates, missing tags/artwork, errors, hidden songs, subset restore,
  playlist membership, favourites, and original files remaining intact.
- Actual changed-file rescanning preserved edits. Repeated edits, reopening the
  database, FTS/album grouping, reset to the latest file details, validation, and
  byte-for-byte original-file preservation were checked.
- The existing 50,001-song test now also checks collection-wide summary counts;
  this is correctness coverage, not a UI frame-rate benchmark.
- Native dark-appearance review covered the collection overview, selection,
  empty-duplicate state, editor opening/cancel, and the compact filter/table layout
  at minimum window height. Installed build checks also verified multi-selection
  and opening/cancelling the New Playlist prompt. The playlist menu keeps its
  intrinsic width. No real collection metadata or removals were changed
  during manual review. A pre-migration SQLite backup is retained locally in dist.
