# Context menus

Right-click a song, or use its ellipsis, in Songs, Favourites, Genres, artist albums, album details and playlists. Home favourite cards also support right-click. The floating player’s artwork/title and expanded Now Playing artwork use the same song actions; expanded Now Playing includes an ellipsis button.

Song actions include Play/Pause/Resume where appropriate, Add to Playlist (existing or New Playlist…), Play Next, Play Last, Go to Album, Go to Artist, Go to Album Artist when different, Go to Genre when tagged, Get Info, Edit Details, Edit Album Artwork, favourites, Copy (song details/file path/file), Show in Finder and confirmed removal from the library. Playlist rows retain Move Up/Down and Remove from Playlist.

Album cards in Home, Albums and Recently Added share Go to Album/Artist, Play, Shuffle, Play Next/Last, Add to Playlist including creation, Show in Finder and Copy Album Details. Album-detail ellipses expose these same actions. Album actions fetch the complete album independently of the visible search/page. Play Next preserves track order. Unreadable songs are excluded from playback/queue actions but can still be collected in playlists.

Manage Library’s selection menu adds playlist creation/addition and Play Next/Last for the chosen rows, plus navigation for a single selected song. Removed items retain their Restore actions.

Go to Album clears the old search and opens the exact album-artist/title identity after albums load. Artist and genre navigation opens the corresponding scoped search. Now Playing looks up the playing file by its connected folder and indexed track ID, independently of visible rows and filters. Hidden songs and files outside connected library roots do not receive library-edit actions; standalone files retain Play/Pause, Show in Finder and Copy File Path. Lookups are driven by song/library changes, not playback position.

Validation: 117 Swift tests in 14 suites pass, including exact lookup beyond 500 visible rows and lookup under an empty search result, hidden/restored tracks, outside roots and remote URLs. Debug UI checks covered menus in Now Playing, exact album navigation from Now Playing/artist search/right-click Favourites, artist navigation, song/album playlist dialogs, and the artwork dialog. Dialogs were cancelled without changing user data. Current playback stayed paused at the saved position.
