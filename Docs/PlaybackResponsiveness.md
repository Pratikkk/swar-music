# Playback responsiveness

Opening, starting, and seeking prime up to 200 ms of decoded PCM rather than filling
all one second of ring capacity synchronously. The existing 10 ms producer timer
fills the remaining capacity after playback starts. The one-second buffer capacity,
source sample representation, and output rate configuration are unchanged. This
reduces synchronous decode work; it does not mean there was a fixed one-second wait.

Seek requests update the displayed position immediately. One seek runs at a time,
with a single pending target: newer requests replace intermediate targets while the
first operation finishes. The progress sliders and keyboard seeking stay available
while seeking; file changes and other conflicting controls stay blocked. Intermediate
seek completions do not overwrite the latest requested UI position. Failures restore
the engine's actual position and allow retry. Shutdown discards pending work.

Track title and cached queue artwork are shown while opening. Seeking and quick
play/pause actions retain song details. Loading indicators appear only if an operation
is still busy after 250 ms; that delay affects presentation only, not the audio work.

## Verification

The 77-test suite includes three regressions for overlapping seeks, latest-target
coalescing, failed-seek recovery, and shutdown during an outstanding seek. The opt-in
HardwarePlaybackTests exercise the reduced priming with quiet ALAC fixtures, 44.1 to
96 kHz switching, pause/resume, repeated playing seeks, EOF, and output-rate restoration.
No buffer underruns were reported on External Headphones in this run:

| Operation | Observed engine time |
| --- | --- |
| Open, including sample-rate change | 213 ms |
| Start output | 161 ms |
| Seek while paused | 2 ms |
| Seek while playing (three requests) | 101–105 ms |

These are one local fixture run, not an end-to-end click-to-speaker latency measurement
or a before/after benchmark. Slow storage, large codec frames, and other output devices
can behave differently. No full-file silence or timing threshold is asserted by tests.

Remaining work: reusing compatible output sessions, preloading the next decoder, and
keeping the output unit running during a seek. Current playing seeks still stop and
restart AUHAL. Format changes may require a real device-rate transition. WMA seeks
still decode from the beginning for sample accuracy; a fast, accurate seek index is
separate work. These changes do not introduce gapless playback or a bit-perfect claim.
