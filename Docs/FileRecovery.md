# Missing-file recovery

Manage Library → Missing Files retains songs that disappear from a watched folder.
A complete, successful enumeration marks them missing instead of deleting the track
record. Cancelled scans, offline roots, and enumeration/access failures do not infer
that all their files were deleted. Folder failures remain in folder status.
Returning files are inspected again even when their size and modification date are
unchanged, clearing the missing status automatically.

Select one missing song and choose Locate File… (also in its context menu or by
opening the row). The recovery sheet shows the original location and selected new
path before Reconnect. The replacement must decode and belong to an authorised
watched folder. For a new location outside those roots, add its containing folder
first, or reconnect the original folder if the whole collection moved.

Reconnect Folder is available in the page header, including compact windows, and
next to each expanded folder status. Choose the root that retains the original
relative album/song paths. Its bookmark, watcher, and root path are replaced while
its identity remains stable. Overlapping roots and roots with none of the original
song paths are rejected. A partial match reconnects the root; any remaining absent
songs stay available in Missing Files. Files and folders on disk are never moved,
renamed, or deleted by recovery.

Reconnecting a song preserves its stable ID, original added date, local metadata
and artwork corrections, favourites, playlist membership/order, and listening
history. If its new path has already been scanned, that entry is merged into the
missing song transactionally: its playlist entries are repointed, listening counts
are combined, and favourites are retained. Both playlist occurrences are preserved
when both entries were present. The missing song's local corrections take priority;
otherwise the imported entry's corrections survive. Excluded destination entries
must first be restored explicitly. Invalid files leave existing records intact.

Migration `library-missing-files-v10` adds `tracks.isMissing` and a unique location
index. Scan fingerprints now carry stable IDs so relocated songs retain identity on
future scans. A small map of exceptional IDs supports URL lookup independently of
search and paging, including when another file later occupies the original path.
Decoding and root checks run away from the main actor. Recovery and scanning do not
mutate locations concurrently.

This protects records from this version onward; records already deleted by older
scanners cannot be recreated with their former history. Explicit Remove from
Library and Remove Folder retain their existing semantics. Already queued items
keep their original file URLs; queue the recovered song again to use its new path.

Regression coverage includes missing/returning files, failed enumeration,
replacement already indexed, metadata and artwork preservation, playlist duplicates,
merged listening counts, favourite retention, root reconnection and overlap/wrong
root rejection, invalid/unwatched replacements, original-path reuse, rescans, and
restart persistence.

Validation: 262 tests in 40 suites passed, including upgrading a v9 database while
retaining favourites, playlists, and history. The universal Release package passed
its bundled codec decode/seek/EOF check. Installed build 100 was checked for the
Missing Files filter and empty state, folder recovery sheet, native folder picker,
and cancellation. The real collection remained at 328 songs and 209 albums; no
files were moved or recovery mutations applied during native UI review.
