# Song sorting

Songs and Favourites offer Sort Songs in the view-options menu beside Search. Choose Album, Song Title, Artist, Duration (shortest first), or Recently Added (newest first). Reverse Order reverses the selected primary ordering. Album ordering groups album artists and albums, preserving disc/track order within each album. Equal primary values retain stable album/disc/track/title/id tie-breakers.

The sort and reverse preference are saved locally and shared by Songs and Favourites. Other sections retain their existing ordering; Recently Added remains newest first, and playlists retain their custom order. Search and favourite filtering apply before sorting and pagination. Changing sort resets the loaded limit to 500; Load More extends the same sorted prefix. Obsolete asynchronous reloads cannot overwrite a more recent sort choice.

Starting a track creates a queue from the currently loaded tracks in their displayed order. Changing the browsing sort leaves an existing queue unchanged. Shuffle remains explicit.

Validation: 94 package tests in 13 suites passed. New coverage checks every sort and reverse direction before pagination, counts, stable ties, and Recently Added precedence. Debug build succeeded. Manual checks verified title ordering, reversed title ordering, normal/reversed album ordering, and sorting-menu availability in Favourites. Preferences were restored to Album without Reverse Order, and the paused playback session was preserved. Playback queue construction uses the unchanged song-list path; audio playback was not separately exercised in this pass.
