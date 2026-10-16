# Swar

A native macOS local music player built with SwiftUI and Swift 6.

## Current milestone: project foundation

The app has a native library sidebar and section-specific empty states. Importing,
decoding, playback, and format reporting are not implemented yet.

Open `swar.xcodeproj` in Xcode and run the `swar` scheme on My Mac.
The app supports macOS 14 or later. Signing uses the existing automatic signing
configuration; select your own team when building on another machine.

## Architecture

`Packages/SwarKit` is a local Swift package with separate module targets:

- `Decoding`: source formats and codec implementations.
- `AudioEngine` → `Decoding`: AUHAL, device control, PCM buffering.
- `FormatInfo` → `Decoding`: pure format and signal-path presentation logic.
- `Library` → `Decoding`: scanning, tags, artwork, and persistence.
- `Player` → `AudioEngine`, `FormatInfo`, `Library`: observable playback state.
- `SwarUI` → `Player`: native SwiftUI views.

The Xcode app owns window setup and dependency wiring. Only SwarUI contains
implementation at this stage; other targets intentionally contain documentation
stubs so their dependency boundaries can build before implementation.

The template's SwiftData model was removed. Persistence is deferred to the library
milestone, where GRDB is planned. There are no external package dependencies yet.

## Sandbox and audio verification

The existing app sandbox, read-only user-selected file access, and hardened runtime
remain enabled. Persistent folder bookmarks and sandboxed DAC/hog-mode behavior
still need implementation and validation before the distribution decision.

The planned playback path is AudioToolbox decoding into an AUHAL output unit.
Do not display bit-perfect status until actual source and output behavior is
verified. The next milestone is decoding and playing one native-format file.
