# Album artwork editing

In Manage Library, select songs and choose Artwork… in the selection toolbar, or
Edit Album Artwork… from the row context menu. The editor previews the cover before
Save. When the selection belongs to one album, Entire album is the default and
fetches every visible song by exact album-artist/title identity, beyond the current
page. Selected songs limits the operation to the captured selection. Mixed-album
selections apply only to selected songs. Cancel does not change stored artwork.

Choose Image uses the native file picker. Images must be regular files no larger
than 20 MB and readable by ImageIO. Decoding, orientation correction and PNG
thumbnail generation run off the main actor; custom covers are stored persistently
at up to 1024 pixels under content-derived names. Existing scan thumbnails retain their
384-pixel size. No image is downloaded and no audio file or embedded tag is changed.

Migration library-artwork-v7 adds independent per-track artwork overrides. Applying
covers is transactional. Rescans save the latest original cover before reapplying
the custom cover. Reset Artwork restores each target's own latest scanned cover,
including no artwork when the source had none. It leaves text metadata corrections
intact. Removing track records cascades artwork overrides.

Save and Reset update library rows, album/Home summaries, and all matching copies
in the current queue, including Now Playing and system media artwork. Queue IDs,
order, position, and playback state stay unchanged; artwork updates do not reopen
the engine. Covers changed while a queued track is opening are retained when the
open completes. Session persistence picks up updated queue artwork normally.

## Validation

- 111 tests in 13 suites passed, and the Debug app built successfully.
- Tests cover valid/invalid/oversized image import and source preservation;
  database reopen, real rescans, replacement/reset including an absent original;
  independence from text metadata; album-wide changes across 601 songs; subset
  reset, invalid cache keys, missing-artwork counts, and foreign-key cleanup.
- Player tests verify duplicate queue copies update together without opening audio,
  seeking, changing IDs/order, or stopping playback. A gated open checks the race
  between artwork replacement/reset and track opening.
- Native dark-appearance review verified selection handoff, the 19-song album scope,
  native file picker, chosen-image preview, enabled Save, switching to the one-song
  selection, and cancelling. The actual library retained zero artwork overrides.
- The pre-existing source-file EOF error seen during testing was not changed by
  this feature. No new physical audio-device testing was required or claimed.

## Durable imported artwork (build 80)

Imported covers now live in `Application Support/Swar/CustomArtwork`; generated
source-cover previews remain in `Caches/Swar/Artwork`. Library keys still identify
the same content, so no database schema change is required. Startup atomically
copies existing `custom-*.png` assets into persistent storage without overwriting
an existing durable asset or deleting the legacy cache copy. Restored queue URLs
are redirected to the durable copy once library/session restoration completes.
The scanner checks the durable location before deciding a custom-art track needs
reinspection. Cache cleanup and rescanning cannot erase the imported cover.

Regressions verify cache purge, rescanning, app restart, legacy migration,
preservation of old queue URLs, source-image preservation and repeated migration.
Covers purged before upgrading cannot be reconstructed from the old key alone;
those need to be selected again. This does not embed artwork into music files.
