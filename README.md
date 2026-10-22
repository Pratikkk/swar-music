<div align="center">

<img src="swar/Assets.xcassets/AppIcon.appiconset/icon-256.png" alt="Swar app icon" width="144" height="144">

# Swar

### Your music. Your library. Your listening experience.

**A native macOS music player built for people who love their local music collection.**

Organize a library of favorites, explore album artwork, control your listening queue, and inspect the audio path—all in a thoughtfully designed Mac app.

[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](Docs/Installation.md)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](Packages/SwarKit)
[![Native SwiftUI](https://img.shields.io/badge/UI-SwiftUI-2479C7)](Packages/SwarKit/Sources/SwarUI)
[![Build DMG](https://img.shields.io/badge/Build-GitHub_Actions-2088FF?logo=githubactions&logoColor=white)](../../actions/workflows/build-dmg.yml)

[**Features**](#what-makes-swar-different) · [**Audio**](#an-audio-engine-that-respects-the-source) · [**Formats**](#supported-audio-formats) · [**Install**](#get-swar) · [**Build**](#build-from-source)

</div>

> [!IMPORTANT]
> **Swar is in active development.** Its macOS engine, library, and interface are implemented, but recent audio-fidelity and signal-inspector changes are still undergoing build and real-device validation. **Bit-perfect delivery to a physical DAC is not yet verified.** GitHub Actions builds are ad-hoc signed and not Apple-notarized.

---

## What makes Swar different

### 🎼 A home for the music you own

Swar is designed around **your local files**, not a streaming catalog. Choose your music folders and let Swar build a browsable collection with album art, artists, genres, tracks, and metadata. Watched folders are rescanned as files change. Your audio files stay where they are, and removing a song from Swar's library doesn't delete it from disk.

### ✨ Made to feel at home on macOS

A floating glass player, translucent sidebar, artwork-led album browsing, rich Now Playing screen, and a carefully tuned light/dark visual language—all built with **SwiftUI**, not a web-based desktop shell.

Personalize accent colors, spacing, Now Playing backgrounds, and artwork blur. The interface stays focused on the music.

### 🎧 More transparency about what you're hearing

Tap a track's format chip to inspect the **source format**, **decoded PCM**, **playback conditions**, and **driver-reported output format**. Swar distinguishes a format match from actual sample-integrity evidence, and can show playback underrun diagnostics.

No marketing-style “bit-perfect” badge based on a file extension or matching numbers alone.

## Explore the app

| Your library | Your listening space |
| --- | --- |
| **Albums & artists** — cover grids, sorting, search, disc/track ordering, and album actions. | **Now Playing** — large artwork, track details, seeking, and an Up Next queue. |
| **Playlists & favorites** — manual playlists, smart rules, saved favorites, and queue shortcuts. | **Floating player** — compact transport controls, scrubber, output volume, and track details. |
| **Library management** — edit local metadata corrections, manage artwork, review duplicates and missing details. | **Appearance** — light/dark modes, accents, spacing, and artwork-based backgrounds. |

> Screenshots are not included yet. Capturing the actual app on macOS is preferable to showing mockups as product screenshots.

### The listening experience

- **Queue control:** Play Next, Add to Queue, reorder, remove, clear, shuffle, and Repeat Off / All / One.
- **Gapless transitions:** Compatible adjacent tracks can share the running audio unit and PCM ring without an inserted gap; incompatible formats use a normal transition.
- **Resume later:** Session restoration remembers the current song, queue, position, and repeat/shuffle state, and restores playback paused.
- **Sleep timer:** Stop playback after a selected interval without changing the volume or clearing the queue.
- **System integration:** macOS Control Center / media-key playback commands, artwork metadata, and transport controls.
- **Output selection:** Choose System Default or a specific output device. Device selections are persisted by UID, with disconnect and reconnect handling.
- **Device volume:** Control supported hardware/system output volume without applying a software gain stage to Swar's PCM.

Learn more: [Queue](Docs/Queue.md) · [Gapless playback](Docs/GaplessPlayback.md) · [Audio outputs](Docs/AudioOutputs.md) · [Sessions](Docs/Sessions.md)

## An audio engine that respects the source

```text
Local music file
      │
      ▼
Native AudioToolbox decoder
    or bundled FFmpeg fallback
      │
      ▼
Decoded PCM at source sample rate
      │
      ▼
Single-producer/single-consumer
atomic PCM ring buffer (C11)
      │
      ▼
Core Audio / AUHAL render callback
      │
      ▼
Selected macOS audio output
```

Swar is built around **Core Audio** rather than an embedded browser audio stack.

- **Native-rate PCM path.** Supported integer lossless sources remain integer through decoding and the ring buffer; floating-point samples are copied without arithmetic in the PCM bridge.
- **Realtime-aware rendering.** The AUHAL callback is written in C and avoids allocation, locks, logging, and Swift calls on the render thread.
- **Output-format inspection.** The engine negotiates a compatible physical format when one is advertised and reports mismatches instead of silently treating every device as identical.
- **Device-aware playback.** Source and output information stay separate, including sample rate, precision, channel count, and physical transport.
- **Focused regression coverage.** Decoder sample references, PCM ring ordering, EOF handling, gapless boundaries, and callback checks are part of the testing effort.

**An important distinction:** passing decoder and render-buffer sample tests does **not** establish end-to-end bit-perfect output at the DAC. macOS mixing, device behavior, volume and transport can affect the final signal. Swar's inspector deliberately presents *Not verified* when evidence is insufficient.

Read the details in [Audio signal inspector](Docs/AudioSignalInspector.md), [Codec verification](Docs/Codecs.md), and [Audio outputs](Docs/AudioOutputs.md).

## Supported audio formats

| Family | File / codec examples | Decoder path |
| --- | --- | --- |
| Lossless | FLAC, ALAC, WAV, AIFF/AIFC, CAF | AudioToolbox |
| Lossy | MP3, AAC | AudioToolbox |
| Additional lossless | WavPack, Monkey's Audio (APE), WMA Lossless | Bundled FFmpeg |
| Additional lossy | Vorbis, Opus, WMA | Bundled FFmpeg |

DecoderFactory tries the native implementation first, then the bundled FFmpeg implementation where appropriate. Bundled codecs do not require a separate Homebrew installation.

**Current limits:** Multichannel output, DSD playback, WavPack correction-file playback, and some less-common format variants remain unsupported or incompletely verified. See [the codec matrix](Docs/Codecs.md) for tested combinations and caveats.

## Take control of your library

**Bring your own folders.** Add read-only monitored music folders; Swar indexes tags and embedded/folder artwork, tracks changes, and supports background rescans.

**Find something worth playing.** Browse albums, artists, genres, songs, favorites, recently added collections, and listening history. Search across titles, artists, albums, genres, and other indexed fields.

**Make it personal.** Organize songs into manual playlists or create **Smart Playlists** with rules, sorting, previews, and optional limits. Smart membership updates when your library changes.

**Keep your originals intact.** Metadata and artwork corrections can be stored locally in Swar without rewriting the underlying audio files. Manage missing artwork, incomplete details, duplicates, and removed items.

Explore [Library](Docs/Library.md) · [Smart Playlists](Docs/SmartPlaylists.md) · [Collection management](Docs/CollectionManagement.md) · [Artwork editing](Docs/ArtworkEditing.md)

## Get Swar

**Requirements:** macOS 14 or later · Apple Silicon or Intel Mac.

### Option A — Build a DMG with GitHub Actions

1. Open [**Actions → Build DMG**](../../actions/workflows/build-dmg.yml).
2. Select **Run workflow**, choose your branch, and enter a version such as `1.0.0`.
3. Inspect the tests and packaging steps. If they succeed, download the generated DMG from **Artifacts** or the run summary.
4. Open the DMG and drag **Swar** to **Applications**.

Workflows are **manual**; pushes do not automatically publish an installer. Artifacts are temporary, and the development builds are **ad-hoc signed, not notarized**. This repository does not currently promise a public, signed release download.

### Option B — Build locally

Install Xcode, clone the repository, and open `swar.xcodeproj`. Select the **swar** scheme and **My Mac**, then build/run.

Run package tests:

```bash
swift test --no-parallel --package-path Packages/SwarKit
```

Build a local installer:

```bash
./scripts/package-macos.sh dist
```

See [installation and updating](Docs/Installation.md) for packaging, signatures, checksums, and troubleshooting.

## How Swar is built

```text
swar/                    Native macOS app, menus, assets
Packages/SwarKit/
  Sources/
    SwarUI/              SwiftUI library & player interface
    Player/              Playback state and queue coordination
    Library/             Library scanning, persistence & search
    FormatInfo/          Quality labels and signal-path diagnostics
    Decoding/            Native and FFmpeg decoding
    AudioEngine/         Core Audio device and session management
    RealtimeAudio/       C11 atomic PCM ring and render callback
Docs/                    Design and implementation notes
Tools/                   Validation and development tools
scripts/                 Packaging and build scripts
```

**Technology:** Swift 6 · SwiftUI · Core Audio / AUHAL · AudioToolbox · C11 atomics · SQLite/FTS5 via GRDB · bundled FFmpeg.

Swar uses sandboxed read-only access to user-selected music folders. See [library implementation](Docs/Library.md) and [installation notes](Docs/Installation.md).

## Development status

Swar is evolving through small, reviewable milestones. Implemented capabilities include native library browsing, playlists, queue management, music decoding, audio output controls, and the signal-path interface. Recent changes to output negotiation and the audio inspector are **not yet release-verified across hardware**.

Current validation priorities:

- Passing the full automated macOS test suite on the feature branches.
- Confirming actual audio output and format negotiation on built-in outputs, USB DACs, Bluetooth, and AirPlay.
- Testing hot-plug, extended listening sessions, and underrun recovery.
- Measuring physical-output sample integrity before making bit-perfect claims.
- Finishing accessibility and visual QA for the expanded audio inspector.

For technical deep dives, browse the [Docs](Docs/) directory.

---

<div align="center">

**Built for the music you return to—not the endless scroll.**

*Swar · स्व*

</div>
