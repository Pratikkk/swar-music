# Listening history

Open **Listening** in the sidebar or **Listening history** on Home. The three views show:

- **Recently Played:** each library song once, ordered by its latest qualifying play.
- **Most Played:** lifetime qualifying plays, with the latest play breaking ties.
- **Forgotten Favourites:** favourites never played in Swar, followed by those last played more than 30 days ago.

A qualifying play requires 30 seconds of observed playback progress, or half the duration for songs shorter than a minute. Pauses and seeks do not contribute; restarting or repeating a song starts a new play. Time between refreshes is capped at two seconds, so long application suspensions cannot fabricate plays. This deliberately undercounts listening while the application cannot observe playback. Restoring a paused session does not count as a play. Standalone files outside the library are excluded.

Only the play count and last-played date per song are stored, in the local library database. No listening data is uploaded. History starts with this version; earlier listening cannot be reconstructed. Counts survive normal rescans and metadata edits. Hidden songs are excluded from views and totals; restoring them restores their prior statistics. Permanently removing a source folder or reconciling deleted files removes their statistics along with the track record.

Search uses the library's field selector and full-text index before limiting results. Pages initially show 100 songs and can expand to 10,000. Statistics cover all visible library history, independently of the current view or search.

**Clear History…** requires confirmation and resets all counts and dates, including hidden tracks. It keeps songs, playlists, favourites and artwork. It cannot be undone.

Validation covers pause/resume, seeks, repeats, one count per playback, short tracks, suspended/invalid samples, persistent storage, ranking, search before pagination, stale timestamps, hidden/restored songs, rescans, clearing and folder deletion.
