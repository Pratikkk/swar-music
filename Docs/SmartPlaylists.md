# Smart Playlists

Use **Playlists → + → New Smart Playlist…**. Start with Favourites, Recently Added,
or Lossless, or build rules for artist, album, genre, year, favourite status, date
added, format, bitrate, and lossless status. Give the playlist a name and Save.
Use **Edit Rules…** on its page or sidebar context menu to revise it later.

Match **All** rules for an intersection or **Any** for a union. Text rules are
case-insensitive and treat punctuation literally. Artist rules check both artist
and album artist. Format refers to the indexed codec tag (for example FLAC or
ALAC). Bitrate is in kbps; unknown bitrates and years do not match numeric rules.
Year uses the first four digits of a year/date tag. Relative dates use rolling
24-hour days, with an inclusive “within” boundary.

Sorting runs across the whole matching library before the optional limit, which
accepts 1–10,000 songs. Reverse order reverses the selected sort’s normal order;
Recently Added normally places newest songs first. The preview counts all matches
and displays at most eight sample songs. Up to 20 rules are supported.

Smart Playlists save rules rather than copies of membership. Imports, metadata
edits, favourites, and library removals affect results automatically. Open playlist
pages refresh relative date rules every minute and evaluate again on reopening.
Hidden songs are excluded. Manual Add to Playlist menus only list ordinary
playlists; Smart Playlists use rule editing instead of manual addition, removal,
or reordering. Starting playback captures a queue, so later rule changes do not
alter the active queue. Source audio files are untouched.

Schema migration v8 adds nullable rule storage and preserves existing playlists.
Invalid or unsupported definitions show an error rather than silently becoming
ordinary playlists or matching every song.

## Verification

The package suite passes 126 tests in 15 suites. Smart Playlist coverage includes
full-library matching, All/Any, sorting and limits, literal and Unicode text,
numeric/date boundaries, favourite/hidden/metadata updates, folder removal,
manual-playlist guards, persistence, editing, and migration preservation.
Native UI checks cover settled previews, All/Any, empty matches, limit validation,
saving, reopening rules, and cancelling edits. A Lossless playlist was created
with three matching songs in the local library.
