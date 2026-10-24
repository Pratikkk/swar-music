# Resource efficiency and lifecycle checks

The audio producer retains its 10 ms cadence during playback. Its dispatch timer
is parked at a distant deadline when there is no playing session, including
pause, end-of-track, failure, and shutdown. It is rearmed on resume. The library
window's 200 ms playback polling task also exists only while playing. Hardware
volume monitoring and periodic session persistence remain available while paused.

Engine destruction and explicit shutdown close synchronously on the serial audio
queue. Calls from outside the queue drain pending work first; calls already on it
close inline to avoid a synchronous dispatch deadlock. Session close stops and
disposes AUHAL before destroying the render ring and restoring the device.
Repeated shutdown remains safe. The previous destructor retained state in an
asynchronous close, so state was kept alive but cleanup could outlast the engine.
Three device-free lifecycle tests check waiting for pending queue work, destruction
and repeated shutdown on the queue, and repeated shutdown off the queue. The full
suite passed 131 tests in 17 suites. These tests do not exercise physical callbacks.

## Device status without blocking snapshots

`EngineState.snapshot()` now reads cached output status instead of calling HAL to
validate device liveness/rate and fetch physical format/transport. A per-session
monitor performs those read-only queries on a separate utility queue every 500 ms
while playing. Its timer parks while paused or closed. The producer checks cached
errors before filling PCM, so detected disconnect/rate changes pause playback even
without UI polling. Invalid status clears the cached output description.

Monitor probes capture immutable identifiers, never the output-session object or
its mutable restoration state. A generation check discards a probe completing
after pause, reset, or close. The cache lock only copies small values; driver calls
run outside it, and snapshots never wait for the monitor queue. Configuration,
explicit play/resume validation, and restoration still query HAL synchronously on
the engine queue. This change isolates periodic reads, not every Core Audio call.

Device-free tests hold a probe blocked while reading cached status, reject stale
failure results after reset, check error propagation, and verify inactive cache
reads do not query the device. The full suite passed 134 tests in 18 suites.
Detection uses polling, not an immediate notification or a hard latency guarantee;
it depends on monitor scheduling and driver response time. Physical disconnect,
external rate changes, and audio underruns were not hardware-tested for this change.

## EOF-tail underrun accounting

A short ring read rechecks EOF after copying the initially available samples. If
the producer published EOF during that copy, the reader acquires the final write
position, copies any newly published final PCM, and zero-fills the remaining tail
without increasing underruns. Reads after the final drain remain silent and do
not advance consumed frames. Genuine shortages observed before EOF publication
still count; finish does not erase earlier starvation. The producer must publish
finish after its last write and must not write again until a stopped reset.

`Tools/verify_ring_eof.c` deterministically publishes EOF during the copy, both
with and without an additional final write. Its test-only copy interposition
includes the production C source; no hooks or interposition ship in the app.
Both cases fail against the previous implementation (three false underrun frames)
and pass with the fix. Run from the repository root:

```sh
clang -std=c11 -Wall -Wextra -Werror \
  -I Packages/SwarKit/Sources/RealtimeAudio/include Tools/verify_ring_eof.c \
  -framework AudioUnit -framework AudioToolbox -o /tmp/swar-verify-ring-eof
/tmp/swar-verify-ring-eof
```

The full package suite passed 135 tests in 18 suites, including partial final
blocks, repeated late drains, reset/starvation counting, packed-24-bit wraparound,
and concurrent producer/consumer ordering. These checks do not measure physical
output underruns.

Player snapshots update observable values only when they change. Source/output
format descriptions are rebuilt only when their inputs change, and unchanged
hardware volume no longer invalidates its views. Library reloads retain the
existing track array and preferences when results are identical. Unchanged scans
skip intermediate library queries while retaining the final deletion reconciliation.

Folder events arriving during a scan request another pass instead of cancelling
the in-progress pass. Scan ownership is explicit so shutdown cancels active work;
cancellation propagates into detached directory enumeration. Metadata inspection
uses a per-file autorelease pool inside the existing four-worker limit. A cancelled
scan does not reconcile missing files. Removing a folder refreshes playlist data
and invalidates open playlist contents without deleting source files.

Verification:

- 87 package tests passed, including unchanged observation notifications, cancelled
  scan reconciliation, monitored folder updates, and folder/playlist removal.
- Debug and Release macOS builds succeeded.
- The opt-in CoreAudio playback test passed with quiet local fixtures: 44.1/96 kHz
  transitions, pause/resume, paused and playing seeks, end-of-track, zero reported
  underruns during the checks, and restoration of the original device sample rate.

These checks validate the work removed and playback behavior. They do not establish
a percentage reduction in CPU, memory, or battery consumption; no controlled
before/after resource benchmark was performed.

## Volume slider commits

Both floating and expanded players share VolumeControl. Pointer dragging updates
only the slider's local draft; its editing-end callback sends the final value to
Player once per completed drag. Keyboard/accessibility changes that do not emit
editing callbacks still commit immediately. Existing Player coalescing remains as
a safeguard for those adjustments and other callers; no delay or timer is added.

A drag remembers its output device and is cancelled if the device changes, controls
become unavailable, or the view disappears. The asynchronous commit checks the
device identity and control availability again before calling Player.setVolume,
so an old draft cannot change a newly selected output. This remains device-wide
HAL volume; the PCM path is untouched.

Validation: package Debug and universal Release build 74 passed, including signing
and bundled-codec checks. Five existing volume-related tests passed. Native
accessibility Increment/Decrement changed the output from 50% to 60% and restored
50%; the paused playback position was preserved. Pointer automation did not move
either the volume slider or the unchanged seek slider, so pointer-drag verification
was inconclusive; no measured HAL write-count reduction is claimed.

## Stable volume presentation after release

Build 74 switched the slider's getter back to the old HAL snapshot at drag end,
before the asynchronous write completed. It also reseeded the local value when
editing began, which could overwrite an initial binding update from native input.
VolumeControl now always binds to VolumeSliderState's local value. It retains the
chosen level while the latest request is queued or being written, then adopts the
confirmed hardware value (including device quantization). Idle external changes
still synchronize normally. Help and accessibility values use the same preview.

Each request has an identity and output device. Older completions cannot overwrite
a newer edit; entering another drag invalidates a not-yet-submitted request without
resetting the thumb. Device changes, unavailable controls, disappearance, and
rejected writes restore the appropriate actual level. Player exposes its existing
volume-write status so a coalesced call returning early cannot prematurely end the
preview. The signal remains true until the hardware queue has drained; no new
polling or timer is introduced. Pointer drags still commit on editing end.

Validation: 156 tests passed in 21 suites. Six new presentation tests cover delayed
confirmation, stale snapshots, quantized confirmation, binding-before-edit ordering,
coalesced/older completions, a new drag during a write, device changes, cancellation,
external changes, and rejected writes. A further focused run passed 11 volume tests,
including checks that Player's writing status spans all coalesced writes. Universal
build 75 passed signature and bundled-codec checks and was installed. Floating and
expanded controls rendered and native accessibility adjustments worked; the saved
paused position remained intact. The delayed-hardware handoff is covered by state
regressions rather than a measured pointer animation/FPS test.


## Lightweight library display queries (25 October 2026)

Songs, album details, collection management and search suggestions no longer fetch
raw tag JSON for display. That payload can include long lyrics/comments. The
schema-derived display projection substitutes NULL for tagsJSON; the database,
full repository queries and exact-track lookups preserve the original payload.
No audio or file metadata is rewritten. Sorting, FTS matching, collection summary
counts and metadata editing still use the stored data. Scan fingerprint checks
reuse an artwork existence result once per key per scan, while a new scan checks
again so deleted cached covers are regenerated.

An opt-in benchmark seeds 1,000 songs with 64 KiB lyric payloads and reads the
same display fields using the full and lightweight query paths. Three separate
processes per mode measured median query time of 68.4 ms versus 16.5 ms, and
median process peak RSS of 198.7 MiB versus 94.0 MiB. The lightweight result
retains zero raw tag bytes instead of 65,549,000 bytes. These are synthetic
benchmark-process measurements, not whole-app memory or scrolling FPS claims.

Reproduce with `SWAR_BROWSE_BENCHMARK=full swift test --skip-build --package-path Packages/SwarKit --filter BrowsingMemoryTests.largeTagPayloadBenchmark`, then
repeat with `SWAR_BROWSE_BENCHMARK=light`. Build the package tests first and run
modes in separate processes; omit the environment variable for ordinary tests.
