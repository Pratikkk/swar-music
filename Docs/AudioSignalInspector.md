# Audio signal inspector

The FormatChip remains compact in player surfaces. Selecting it opens a four-stage
inspector: source file, decoded PCM supplied to AUHAL, playback conditions, and
driver-reported physical output. The popover supports sharing a plain-text
diagnostic report and shows live underrun-frame counts.

## Evidence boundaries

- **Source** comes from the active decoder and describes encoded media.
- **Decoded PCM** comes from the active decoder's AudioStreamBasicDescription.
  Container size and valid precision are different: 24 meaningful bits in a
  32-bit container does not by itself prove sample conversion.
- **Output** is the Core Audio driver's reported physical stream format, not
  independently captured digital output.
- **Status** does not claim bit-perfect playback solely because formats match.
  The default sample-integrity state remains *Not verified*. Decoder/ring
  regression tests are not proof of end-to-end DAC sample identity.
- **Underrun frames** count missing frames and indicate a playback-continuity
  problem, not necessarily PCM conversion. They are included in diagnostics.

Diagnostic sharing contains track-format and output details, but does not
include paths or audio file contents.

## Verification

Run `swift test --no-parallel --package-path Packages/SwarKit`.
Exercise the chip with 16-bit ALAC/FLAC, 24-bit files, 32-bit float audio,
MP3/AAC, disconnected outputs, and forced underrun conditions. Confirm that
the source, decoder PCM, and output fields stay distinct as playback changes.
Test VoiceOver and increased-contrast modes on macOS.
