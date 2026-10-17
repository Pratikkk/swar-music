# Appearance

Open Settings (⌘,) → Appearance.

- Theme: System follows macOS; Light and Dark apply to Swar independently.
- Accent colour: Violet (default), Ocean, Forest, Rose or Amber. Selections, playback actions, favourites and quality accents use the same palette. Dark mode uses lighter foreground accents while filled controls retain white labels on deeper colours.
- Spacing: Comfortable (default) or Compact. Compact reduces sidebar and song rows, management table artwork, and album/artist/Home gaps. Album artwork size remains independently adjustable in Albums. Transport geometry and text sizes stay stable.

Preferences are stored in the app’s UserDefaults and observed at the library and Settings scene roots. Environment values propagate to sheets and popovers. Changing appearance does not replace the library/player identity, restart playback, or rescan files. Invalid stored enum values fall back to defaults. No library migration is required.

Validation: Debug build and 111 existing Swift tests pass. Manual checks cover live Light/Ocean/Compact and Dark/Forest/Comfortable changes, album browsing, Files settings, restart persistence, and return to System/Violet/Comfortable. The paused queue, 17.914-second position and device volume remained unchanged.
