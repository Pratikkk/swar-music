# Expanded Now Playing

Click the floating player's artwork or song details, or use ⇧⌘N, to open the expanded player. Escape or the collapse button returns to the library. The sheet is 650 points high and follows the window width between 640 and 900 points.

Artwork supplies a low-opacity blurred background over an appearance-aware base. Reduce Transparency removes that background. Artwork and metadata use short crossfades that respect Reduce Motion; artwork decoding reuses the existing bounded thumbnail cache. Presentation retains fixed title, quality-chip, and status slots so transport controls do not move as songs change. No new playback or volume polling is added.

The hierarchy is artwork, title, clickable artist/album, audio-quality chip, and a compact status line. Artist and album links dismiss the sheet and browse matching library results in the appropriate search field. Errors and session notices remain available, with long messages exposed through help and selection. The former duplicate Resume banner/button is replaced with Ready to resume and one main transport button.

The fixed controls area contains elapsed and remaining time, a wide seek slider, a reserved Seek to time preview during dragging, Shuffle, Previous, Play/Pause, Next, the same cycling Repeat button as the floating player, volume, and the output device name. A seek targets the song on which the gesture began and is discarded if the song changes or a conflicting operation starts. The sleep timer remains in the header.

Up Next sits beside the artwork at widths of at least 800 points. At narrower widths it replaces the artwork area while the complete playback controls remain visible below. Queue rows retain artwork, reordering, removal, and playback actions. The queue list background is transparent over its panel.

Validation: 101 package tests in 13 suites passed and the Debug build succeeded. Manual checks covered the restored paused state, a single Resume control, artist/album navigation, click-to-seek and accessibility seeking, wide and narrow queue layouts, and restoring the window size. The existing song remained paused, its position was restored to approximately eight seconds, and output volume was preserved. The seek preview and crossfades are implemented; pointer dragging, live song transitions, dark appearance, and accessibility preference changes were not separately verified in this pass. Hardware audio behavior is unchanged.
