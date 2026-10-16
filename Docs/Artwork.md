# Artwork and track recognition

A shared CoverArt view renders local cached covers in album grids/headers, Songs,
artist and genre track lists, the Now Playing bar, and current/upcoming queue entries.
Sizes are 44 points in library rows, 40 in the queue, and 56 in the player. Missing or
unreadable images use a tinted music-note placeholder with the same dimensions.
Covers are decorative for accessibility; track text and transport labels identify
the song and its current playback state.

The Now Playing bar separates title/artist/album and transport controls from the
format chip, scrubber, and times. It fits the app's 760-point minimum window width.
The current library row uses a subtle accent background and a waveform/paused badge.
Its play button toggles playback rather than rebuilding the queue.

QueueEntry carries the library thumbnail URL and subtitle through queue changes.
Player clears presentation on failed opens and shutdown, preventing stale covers.
Standalone file opens read tags and embedded/folder covers off the main actor while
holding the file's security scope. They use the same disk artwork cache as scanning;
opening a file does not add it to the library. Thumbnail failures leave audio usable.

CoverArt uses ImageIO on a cache actor, with thumbnails limited to 384 pixels. The
shared NSCache has a 256-image/32 MiB budget. A cancelled view task cannot replace
artwork for a newer URL; mismatched URLs show a placeholder immediately. Existing
content-addressed disk cache keys allow safe reuse across rows and player surfaces.

Verification: three new tests cover standalone tag/cover extraction and cache reuse,
queue artwork/subtitle changes, and clearing artwork after failed opens. The full
57-test suite passes. The signed sandboxed app was visually checked with real covers
in Songs and the Now Playing bar, current-row highlighting, queue metadata, and the
760-point minimum window layout. Full VoiceOver navigation and dark-mode visual QA
remain to be checked for this layout.
