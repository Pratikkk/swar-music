# Favourites

The Library sidebar includes Favourites, using the same artwork, track options, floating player, and scroll clearance as Songs. Favourite tracks have a pink star beside their title. Use any song’s options menu to add or remove a favourite. Changes update the screen immediately; removing a favourite does not alter the current playback queue.

Search matches only favourites. The database applies the favourite filter before counting and paging, so a favourite outside the first 500 unfiltered tracks remains discoverable. Hidden library tracks remain excluded. Play and Shuffle use the currently loaded, filtered tracks; use Load More to include additional pages before starting playback. Unreadable tracks remain visible but are excluded from playback. No new database migration is needed: existing saved favourites appear automatically.

Reloads snapshot search, sort, and favourite scope and reject obsolete results when navigation changes during a query.

Validation: 93 package tests in 13 suites passed, including filtering before pagination, full-text search intersection, unfavouriting, hidden-track exclusion, and model scope changes. Debug build succeeded. Manual checks covered the empty screen, adding a favourite from Songs, the artwork/star/count and playback controls, search excluding a non-favourite, clearing search, and removing the final favourite. Temporary favourite changes were restored. Audio playback uses the existing song-list queue path and was not separately exercised in this UI pass.
