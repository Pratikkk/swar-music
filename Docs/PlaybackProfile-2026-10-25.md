# Installed-app playback profile — 25 October 2026

## Scope

Profiled `/Applications/Swar.app`, version 1.0.0 build 141, ARM64 on macOS 15.8.1. This is the installed build, not current main (`5ab9552`); results must not be presented as verification of the latest merged source. Real collection: 1,083 songs and 415 albums. Restored queue reported 350 upcoming entries. Source: Aur Ho, AAC ~263 kbps, 44.1 kHz stereo; route: External Headphones, shared float output. No volume writes were issued.

## Method

61 process CPU/RSS samples at five-second intervals over 300.6 seconds, plus 10-second stack samples for Home, expanded player and album browsing, and a 15-second quiet album sample. Exercised expanded Now Playing, queue scrolling, a pointer seek to ~123 seconds, Songs, album list/grid, and grid scrolling. Left the playing album grid without UI queries for a quiet comparison window. Natural EOF restarted the track with the existing Repeat One setting.

Raw observations are local generated files under `dist/QA/2026-10-25/playback-profile/`: resources.csv, phase.txt, and four *.sample.txt stack reports. Phase labels are coarse: the last phase also includes later UI inspection/EOF/restoration; use the explicit 145–230-second interval for the quiet comparison.

## Measurements

| Measurement | Result |
| --- | --- |
| Whole-run median CPU | 2.9% |
| Whole-run sampled peak CPU | 99.5% |
| Initial / peak / final sampled RSS | 135.8 / 611.6 / 494.5 MiB |
| Quiet album playback, 145–230 s, 17 samples | median CPU 1.5%, maximum 3.3% |
| Quiet-window RSS first / peak / last | 465.5 / 466.8 / 287.1 MiB |
| Home stack main-thread event wait | 765 of 808 main-thread samples |
| Expanded stack main-thread event wait | 880 of 908 main-thread samples |
| Quiet album stack main-thread event wait | 1,330 of 1,352 main-thread samples |

CPU uses approximately 100% per logical core. RSS is resident memory, not physical footprint or allocated heap size. Stack counts are wall-time observations, not CPU-time percentages. Do not infer frame rate, seek latency in milliseconds, audible continuity, or leak freedom from these metrics.

## Findings

1. Steady playback had low CPU use in the measured quiet window. The sampled main thread was predominantly waiting for events; there is no evidence here of sustained main-thread saturation by the audio engine.
2. Album grid/Songs accessibility inspection and browsing produced large transient CPU/RSS peaks. The concurrent album stack contains substantial NSAccessibility/SwiftUI accessibility work, whereas the quiet sample is predominantly idle. Automation contributes to the observed peaks; this run cannot attribute all cost to normal pointer scrolling. Memory decreased substantially during the quiet interval, so the peak alone is not evidence of a leak.
3. Installed build 141 visibly freezes elapsed/remaining text while the accessibility waveform position advances. Opening a view or seeking refreshes the text. Current source already reads player.position directly in FloatingPlayerSeekBar and ExpandedSeekBar; do not treat this old-build observation as proof of a remaining main-branch bug. Validate the next installed build separately.
4. Seek, view navigation, queue scrolling, pause and natural Repeat One EOF completed. No crash or playback error was observed. UI automation time includes observation overhead and is not a user-input latency benchmark.

## Next measurements

Install a build of current main and repeat the same workload before changing playback polling. For scrolling, capture a rendering-hitch trace with accessibility queries idle, and compare grid/list on identical routes and artwork caches. Use allocation traces to attribute any retained memory after repeated navigation; current RSS sampling is insufficient. Audible glitches need listening or loopback capture.

## Restored state

Aur Ho paused at exactly 9.914920634920636 seconds, Home selected, album list preference restored, Shuffle Off, Repeat One. Queue contents/order were not edited. Output/volume settings were not written. Listening history may reflect test playback and the repeat.
