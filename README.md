# Swar

A native macOS local music player built with SwiftUI and Swift 6.

For regular use, install the packaged **Swar.app** in Applications. Build a local
DMG with `./scripts/package-macos.sh`; see [installation and updates](Docs/Installation.md).

The library uses a floating glass player, a translucent native sidebar, and artwork-first
album cards, with a warm canvas, violet accents, and serif Home headings. Home
opens with Continue Listening, favourites, recent albums, and watched folders.
Recently Added groups albums by month. See [Swar identity notes](Docs/SwarIdentity.md). Radio is omitted. Open an album by clicking its cover or title, or play it
using the button over its artwork. Album details show large cover art, artist and
genre/year tags, Play and Shuffle actions, numbered songs, duration, and queue menus.
Play starts in disc/track order; Shuffle includes the whole album. Library actions (open file, add folder, rescan)
are in the menu at the right of the section header. The sidebar uses native macOS
blur; library surfaces adapt between warm light and dark appearances.

The floating player and expanded player include an output-volume slider. It controls
the selected playback device (or the default output before playback), follows system
volume changes, and leaves Swar's PCM samples untouched. This is device-wide volume;
outputs without an adjustable control show a disabled slider with an explanation.
See [volume control](Docs/Volume.md).

Swar remembers your queue, current song, position, shuffle/repeat settings, and cover
metadata. On launch it restores a paused session; press **Resume** when ready.
Restoring does not open an audio device or change its sample rate. Pending queues
show **Queue Ready** and can be started with Play. See [session restoration](Docs/Sessions.md).

Swar integrates with macOS Now Playing: play/pause, next/previous, and position
changes use native remote commands, with title, artist, album, cover art, duration,
and playback state supplied to Control Center. Start playback in Swar first; a
restored paused session does not claim Now Playing. See [system media controls](Docs/SystemMediaControls.md).

Covers appear in Songs, artist/genre track lists, albums, the Now Playing bar, and
Up Next. The player shows title and artist/album, with transport controls and a compact scrubber in the bottom floating bar. Current tracks have a cover badge and a subtle row highlight.
Missing artwork uses a consistent tinted music-note placeholder. Local thumbnails
load off the main actor and share a bounded memory cache. Files opened directly also
read their tags and embedded/folder covers without importing them into the library.
See [artwork UI notes](Docs/Artwork.md).

Click the player’s cover, or press **⇧⌘N**, to open Now Playing with larger artwork,
song details, format information, and playback controls. **Up Next** opens beside
the artwork in wide windows and switches to a queue view in compact windows.
Use the queue’s arrow buttons to move tracks earlier/later; Escape returns to the
library without stopping playback. See [Now Playing notes](Docs/NowPlaying.md).

Playback starts and seeks use a smaller initial decode buffer, retain song details,
and coalesce rapid seek requests to the latest position. See [responsiveness notes](Docs/PlaybackResponsiveness.md)
for hardware timings and remaining limitations.
Expanded Now Playing uses an artwork-tinted background, artist/album library links, a wide scrubber with remaining time, and unified transport controls. Up Next keeps playback controls visible in compact windows.

## Current milestone: compact library layout

The app has a native library sidebar and a single-file playback harness. Use
**File → Open Audio File…** (⌘O), then **Space** to play/pause. Left/Right seek by
five seconds; the slider scrubs. Opening a file prepares it without autoplay.
The format chip in album details and expanded Now Playing reports the decoder's source quality and
codec. Click it for source details, device format, and signal-path status. Hover
for a compact summary. An orange dot marks a known conversion. Matching formats
remain **Not verified** until the output path supplies sample-integrity evidence.
Song ellipsis and right-click menus offer Add to Playlist (including New Playlist),
Play Next/Last, Get Info, Favourite, Copy, Show in Finder, and Remove from Library.
Favourites persist locally and have a dedicated sidebar screen with search, Play, and Shuffle. A violet star marks favourite songs. Library removal leaves the original file in place and
keeps it excluded from folder scans; **Settings → Files → Restore Removed Songs**
restores visibility. Playlist references are removed when a song is removed from the library.
Songs and Favourites support saved sorting by title, artist, album, duration, or
recently added, with Reverse Order in the view-options menu. Sorting applies
across the database before paging.
Search covers titles, performers, album artists, albums, genres, years, and file/folder names. Click the search icon to select a field. It matches word prefixes across multiple fields, handles punctuation and Latin accents, and also filters playlist rows.

Artists uses a two-pane browser with All Artists and a selectable artist list.
Album artists keep compilations together, with album covers, numbered songs, and
Play/Shuffle, queue, and playlist actions. Narrow windows stack the songs below
the album heading.

Open **Swar → Settings… → Files** (⌘,) to manage monitored music folders, check
monitoring status, or rescan. New, modified, and removed files refresh automatically
while Swar is open; saved folders are checked again at launch.
Use **Add Folder…** to import a music folder. Swar saves read-only folder access,
indexes metadata and artwork, and watches nested folders for changes. Browse Albums,
Artists, Songs, Genres, or Recently Added, and search titles, artists, and albums.
Use a track’s play button to start playback. Removing a folder from the library leaves its files intact.
See [library implementation and verification notes](Docs/Library.md).

**Play Album** starts an album in disc/track order. A track’s play button starts at
that track and queues the remaining tracks in the current view. Right-click a track
for **Play Next** or **Add to Queue**. The player has previous/next controls
(⌘← / ⌘→) and a Queue popover with Up Next, drag reordering, removal, and Clear Up Next.
Previous restarts the current track after three seconds; otherwise it goes back.
Shuffle mixes upcoming tracks while keeping the current track in place. The Repeat
button cycles Off → All → One; manual Next still advances in Repeat One.
The timer icon pauses playback after 15–120 minutes without changing volume or clearing the queue. The timer can be replaced or cancelled and is cleared when Swar quits.
Queue entries that cannot open keep an error row while the player tries the next.
See [queue behavior and verification](Docs/Queue.md).

Open `swar.xcodeproj` in Xcode and run the `swar` scheme on My Mac.
The app supports macOS 14 or later. Signing uses the existing automatic signing
configuration; select your own team when building on another machine.

## Architecture

`Packages/SwarKit` is a local Swift package with separate module targets:

- `Decoding`: source formats and codec implementations.
- `AudioEngine` → `Decoding`: AUHAL, device control, PCM buffering.
- `RealtimeAudio`: C11 atomic PCM ring and AUHAL callback, used by `AudioEngine`.
- `FormatInfo` → `Decoding`: pure format and signal-path presentation logic.
- `Library` → `Decoding`, `GRDB`: scanning, tags, artwork, SQLite/FTS5, and folder watching.
- `Player` → `AudioEngine`, `FormatInfo`, `Library`: observable playback state.
- `SwarUI` → `Player`, `FormatInfo`, `Decoding`, `Library`: native SwiftUI views and previews.

The Xcode app owns the single main window and menus. Decoding and device calls
run on one background serial queue; the AUHAL callback executes C only, with no
allocation, locks, logging, or calls into Swift. The main-actor observable player
polls snapshots. FormatInfo is a pure source-quality and signal-path classifier;
Library handles background scans and actor-isolated persistence. `DecoderFactory` probes
with AudioToolbox first and falls back to bundled FFmpeg through a small C bridge.
Neither routing nor source-quality classification uses filename extensions.

Source quality and output integrity are independent. Lossless sources above
24-bit or 48 kHz get the hi-res label; these thresholds live in `FormatThresholds`.
Lossy labels include decoder-reported bitrate when available. Known rate, bit-depth,
sample-representation, channel, processing, and wireless-output changes are reported
as Converted. Shared output and unmeasured system volume prevent a verified check.
The engine reads device transport to identify Bluetooth and AirPlay, although those
devices have not been manually tested. DSD labels are covered for future decoders;
DSD playback is not implemented.

Persistence uses GRDB 7.11.1, pinned through Swift Package Manager. FFmpeg is
vendored as headers and dynamic libraries. Third-party licenses accompany the app.

## Sandbox and audio verification

The existing app sandbox, read-only user-selected file access, and hardened runtime
remain enabled. A security-scoped lifetime token keeps an opened file accessible
until the engine closes it. Imported folders use persistent read-only security-scoped
bookmarks. Sandboxed DAC/hog-mode behavior still needs validation before the
distribution decision.

The implemented path is AudioToolbox (`ExtAudioFile`) → native-rate interleaved PCM
→ one-second atomic ring → AUHAL. Integer lossless PCM stays integer in the decoder
and ring. There is no software volume or sample-rate fallback. Mono/stereo sources
are supported; unsupported rates and codecs produce a visible error. The engine
attempts a matching physical bit depth when the driver advertises one, and shows
the driver's actual format even when it differs. System mixing and hardware volume
are still in the signal path. **Bit-perfect output has not been verified.**

Playback uses the default output selected when a file opens. A disconnect or external
sample-rate change during playback stops playback with an error; reopen the file
after selecting a working output in macOS Sound settings. An in-app device picker,
exclusive mode, gapless playback, and automatic device recovery are later work. The previous
device format is restored on file replacement, session cleanup, or app quit where
the device still uses the rate Swar requested. Pause retains the current session.

## Verification

Build with Xcode, or from a terminal with Xcode's developer directory selected:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project swar.xcodeproj -scheme swar -destination 'platform=macOS' \
  -derivedDataPath /tmp/swar-derived CODE_SIGNING_ALLOWED=NO build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path Packages/SwarKit
```

The ordinary suite tests byte-exact packed 24-bit decoding and seeking, ALAC
24-bit/96 kHz round-trip fidelity, content-based detection with a misleading
extension, corrupt files, ring wraparound, concurrent sample order, end-of-file
silence, and error-message persistence. Format tests cover quality boundaries,
custom thresholds, lossy and DSD labels, conversions, unknown output, accessibility
text, and the evidence required for a verified check. The ALAC test uses macOS's
`afconvert`. At the format-chip milestone, the ordinary run passed 22 tests with
hardware playback skipped; the current codec matrix is described below.

The hardware test is opt-in: **it briefly plays a quiet generated tone and changes
the default device rate**. Close other Swar instances before running it:

```sh
python3 Tools/make_audio_fixtures.py /tmp/swar-audio-fixtures
SWAR_TEST_AUDIO_FILE=/tmp/swar-audio-fixtures/quiet-24bit-96k.m4a \
SWAR_TEST_ALTERNATE_FILE=/tmp/swar-audio-fixtures/quiet-16bit-44k.m4a \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path Packages/SwarKit --filter HardwarePlaybackTests
```

Verified during the playback milestone: nine tests passed including live 44.1 → 96 kHz switching,
play/pause, seek while paused and playing, EOF, and original-rate restoration.
The observed output was External Headphones, 32-bit float at 96 kHz. The sandboxed
app also opened and played the generated ALAC through its file picker; Space,
arrow-key seeking, and the accessible slider were checked.

For chip visual checks, Debug builds provide a decode-only harness:

```sh
open /tmp/swar-derived/Build/Products/Debug/swar.app --args --format-chip-preview
```

Quit that copy before launching with the argument. The harness opens real files
through the sandboxed file picker, decodes on a background task, and offers clearly
labelled output simulations without opening an audio device. It is excluded from
Release builds. Light/dark appearance, the stronger chip border, AAC and hi-res ALAC
labels, conversion explanations, and accessibility labels were checked there.
Full VoiceOver navigation and physical Bluetooth/AirPlay paths remain untested.

Still unverified: physical DAC sample equality, a 24-bit integer-output DAC,
hot-plug, sleep/wake, and long-running playback.
Gapless playback and exclusive output remain future work.

## Codec support

The native decoder covers ALAC, FLAC, integer/float WAV, AIFF/AIFC, CAF, AAC, and
MP3. Native FLAC precision is recovered from STREAMINFO when AudioToolbox omits
it. Bundled decoders add Vorbis, Opus, WavPack, Monkey's Audio, and WMA (including
Lossless). Hybrid WavPack is labelled lossy; correction-file playback is not
implemented. DSD is still a future feature.

FFmpeg libraries are included in the project and embedded in Contents/Frameworks;
the app does not require Homebrew or a command-line decoder. Headers and universal
arm64/x86_64 libraries live in `Packages/SwarKit/Vendor/FFmpeg`. The LGPL-only build
recipe, exact upstream source archive, notices, and license accompany the app.
See [codec implementation and verification notes](Docs/Codecs.md).

The current suite has 80 tests, including twenty device-free queue tests, nine session tests,
thirteen library tests (covering search, paging across 50,001 stored tracks, and playlists),
and three device-free volume tests, generated format matrices, and optional
complete APE/WMA Lossless samples. Lossless decoding is compared against SHA-256
references and seek positions against original samples. Integer lossless fixtures
cover 44.1/16, 96/24, and 192/24; float PCM and WavPack are also tested. A signed,
sandboxed app successfully opened Opus using its embedded libraries. Physical
playback on every codec/device combination has not been checked.
