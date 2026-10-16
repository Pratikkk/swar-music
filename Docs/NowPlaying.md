# Expanded Now Playing

Open the expanded view from the cover in the bottom player or Playback → Show Now
Playing (Shift-Command-N). A small expansion badge and tooltip make the cover action
discoverable. Escape or the header's close button returns to the library; dismissal
does not stop playback or replace the queue.

The view shares the existing Player and PlaybackControls. It shows 240-point cover
art, title, artist/album details, the format chip/signal-path popover, larger transport
controls, shuffle/repeat, elapsed time, and a scrubber. A loading indicator covers
transitions. Playback errors and buffer underruns remain visible. No separate audio
session is created for this view.

The sheet sizes to the library window, up to 900 points wide. Up Next is optional:
at 760 points or wider it appears beside the artwork, while smaller sheets switch
between artwork and queue. The Up Next toggle includes the remaining track count.
A scrollable player surface keeps controls reachable with longer metadata/errors.
Open File is disabled while the sheet is presented to avoid competing dialogs.

Both the expanded queue and compact queue popover have explicit Move Earlier/Move
Later buttons with descriptive accessibility labels, alongside drag reordering and
removal. Boundary moves and edits while opening a track are disabled. Full titles
and artist/album metadata appear in row tooltips when text is truncated.

Verification: the signed preview was checked for large real cover art and metadata,
keyboard seeking while paused, Escape back to the library, queue display, moves
in both directions, side-by-side wide layout, compact switching, and blocking file
dialogs while the sheet is open. The queue regression test now also verifies a downward move.
The full 57-test suite passes. Playback remains on the existing engine; this step
does not add gapless handoff, media keys, or full-screen mode. Queue persistence was
added in the [session restoration milestone](Sessions.md).
