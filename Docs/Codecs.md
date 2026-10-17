# Codecs: implementation and verification

The existing player and render callback consume the `AudioDecoding` protocol.
`DecoderFactory` tries AudioToolbox, then the bundled FFmpeg implementation. The
reported codec, precision, sample rate, channels, and available codec bitrate come
from decoded content and codec headers, never a file extension or editable tag.
Container bitrate is not used as a substitute for unknown audio bitrate.

| Family | Primary backend | Verification |
| --- | --- | --- |
| ALAC, FLAC, WAV, AIFF, CAF | AudioToolbox | Generated 44.1/16, 96/24, 192/24 files; full decoded checksums and exact seeks |
| Float WAV, AIFC, CAF | AudioToolbox | 32-bit float/96 kHz; independently calculated IEEE-754 samples |
| AAC (M4A and ADTS), MP3 | AudioToolbox | Generated files, full decode and seek |
| Vorbis, Opus | Bundled FFmpeg | Generated files, full decode and seek; Opus pre-skip and duration checked |
| WavPack | Bundled FFmpeg | All three integer profiles plus 32-bit float; checksum and seek alignment |
| Monkey's Audio, WMA Lossless | Bundled FFmpeg | Complete 16-bit/44.1 kHz FFmpeg regression samples; full reference checksums and seeks |
| WMA lossy | Bundled FFmpeg | Generated WMA v2 file; full decode and seek |
| Hybrid WavPack | Bundled FFmpeg | FFmpeg regression sample confirms lossy classification |

The same integer fidelity matrix also exercises FFmpeg's ALAC and FLAC fallback.
APE and WMA Lossless high-resolution files, WMA Pro, and WMA v1 have decoders
enabled but are not covered by the current sample set. Multichannel routing,
WavPack correction files, and DSD playback remain unsupported.

## Keeping samples unchanged

The C bridge interleaves planar decoder output and repacks native integer
precision, including FFmpeg's left-aligned 24-bit samples in 32-bit containers.
It does not normalize, dither, resample, or convert integer lossless sources to
float. Float samples are copied without arithmetic. The bridge runs on the audio
worker queue; the real-time AUHAL callback still only reads the atomic PCM ring.

### Packed 24-bit extraction review

For the bundled FFmpeg decoders, 24-bit signed integer samples occupy the upper
24 bits of S32/S32P. On supported little-endian Apple Silicon and Intel Macs,
the bridge shifts the unsigned bit pattern right by eight and copies its lowest
three bytes. Logical shifting does not lose the packed sign: `0xFFFFFF00` (-1)
becomes bytes `FF FF FF`, and `0x80000000` (minimum) becomes `00 00 80`.
Arithmetic sign extension would affect only the fourth byte, which is omitted.
Removing the shift would instead retain the padding byte and discard significant
audio bits. No corruption was reproduced in this extraction path.

`Packed24BitTests` forces the bundled bridge for PCM WAV (interleaved S32) and
ALAC (planar S32P), using independently constructed signed extrema and varied
low-bit stereo samples. It compares every output byte, tests irregular reads,
checks buffer guard bytes, and seeks around decoder block boundaries. The
existing FLAC/ALAC/WavPack matrix also checks full decoded reference bytes at
24-bit/96 kHz and 24-bit/192 kHz. The full package suite passed 127 tests in 16
suites after this review. This verifies decoder PCM, not physical DAC output;
optional external APE/WMA fixtures and physical hardware checks remain separate.

Short files without usable seek indexes fall back to an earlier decode position.
WMA/ASF timestamp granularity and decoder preroll made exact direct seeks
unreliable, so WMA seeking reopens the stream and decodes forward in bounded
4096-frame chunks. Memory stays bounded, but seeks far into a long WMA file can
be slow. Reopening verifies that codec, PCM representation, duration, rate, and
channel count still match before exposing new samples.

Damaged packets, unsupported shapes, missing/incompatible libraries, and premature
lossless EOF throw visible playback errors. A truncated FLAC regression case
ensures the stream cannot simply end silently. This is not exhaustive corrupt-file
fuzzing. The format chip's integrity status remains separate from decode fidelity:
**physical DAC sample equality is still unverified**.

## Bundling

The four dynamic libraries are `libavformat.63`, `libavcodec.63`, `libavutil.61`,
and `libswresample.7`. Xcode embeds and signs them in the app's Frameworks folder.
Their dependencies use `@loader_path` and Apple system frameworks only. Runtime
loading checks library major ABIs. No Homebrew paths are searched and playback
never launches an external decoder process.

`Tools/build_codecs.py` downloads the pinned official FFmpeg 9.0.2 archive, checks
its SHA-256, and builds unmodified source for macOS 14+, arm64 and x86_64. GPL,
nonfree, external libraries, network protocols, executables, encoders, and video
decoders are disabled. `libswresample` is required internally by FFmpeg's Opus
decoder; Swar does not call it to resample PCM. Intel slices are cross-compiled
and inspected, but have not been executed on Intel hardware.

```sh
python3 Tools/build_codecs.py
```

The exact source archive, build flags, LGPL text, and upstream license notes are
in the app's ThirdParty resources. [FFmpeg's license guidance](https://ffmpeg.org/legal.html)
describes the upstream obligations. Distribution signing and notarization remain
part of the release milestone.

## Reproduce verification

The checked-in generated fixtures contain original quiet tones, not downloaded
music. Rebuilding them requires a development-only FFmpeg executable:

```sh
python3 Tools/make_codec_fixtures.py Packages/SwarKit/Tests/DecodingTests/Fixtures
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/SwarKit
```

APE/WMA Lossless and hybrid WavPack regression media are downloaded separately
and are not redistributed in this repository or application. The optional tool
pins media checksums and verifies the independently decoded PCM reference:

```sh
python3 Tools/fetch_codec_regression_samples.py /tmp/swar-external-codec-fixtures
SWAR_EXTERNAL_CODEC_FIXTURES=/tmp/swar-external-codec-fixtures \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/SwarKit
```

These checks do not emit audio. The earlier hardware test remains explicitly
opt-in. The latest run passed 32 tests, with hardware playback skipped. App-level
verification used a locally signed sandboxed build, checked its entitlements and
nested signatures, then opened an Opus fixture through its file picker in the
decode-only preview. Broader physical playback, hot-plug, and sleep/wake testing
remain outstanding.
