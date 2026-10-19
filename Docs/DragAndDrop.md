# Drag and drop

- Drop one or more music folders onto a library browsing page or Add Folder in the sidebar to add and monitor them. Existing folder overlap checks and read-only bookmarks apply. Files stay in place.
- Drag a song row from Songs, an album, an artist, Home, listening history, or a playlist onto a manual playlist in the sidebar or its open page.
- Drop songs on the floating player's queue button or inside Up Next to append them without interrupting playback. The queue's existing handles still reorder upcoming entries.
- Smart playlists are controlled by their rules and reject song drops. Finder song files are not imported by the folder target: add their containing music folder first.

Song drags use a custom data representation and re-resolve each file against the database before changing anything. Hidden/removed tracks and disconnected folders are rejected. Drop order and duplicate entries are preserved. A failed resolution leaves the destination unchanged. Busy/sleeping playback rejects queue drops, and scanning temporarily disables folder drops.

Tests cover payload validation, stale references, filtered libraries, ordering, duplicates, playlist insertion, and queue insertion using an isolated library.
