# Waveform seek bar

The floating and expanded players show a full-song waveform with live played
progress, a playhead and the existing elapsed/remaining times. Click or drag anywhere
to seek. Left/Right move one second in the floating player and five seconds in the
expanded player; the accessibility representation remains a
native playback-position slider. Existing throttled/coalesced seeking and preview
handoff are retained. Settings → Now Playing → Show song waveform switches back to
the standard slider. This is an amplitude overview, not a live frequency spectrum.

Analysis opens a separate decoder on a utility task. It never reads or modifies
playback's decoder/ring buffer, changes device settings, or processes output PCM.
The waveform contains 512 full-timeline energy buckets: 82% RMS energy and 18%
peak amplitude. Channel energy is combined before taking the RMS, so opposite
phases do not cancel. Sustained music and brief equal-height peaks remain distinct. Integer 8/16/20/24/32-bit and float
32/64-bit PCM layouts are handled, including byte order, signedness and high-aligned
containers. Drawing uses per-song visual normalization; waveform height is not a
calibrated loudness meter. Non-finite samples are ignored. The version-2 cache key
regenerates existing peak-only waveforms without changing source files.

Rounded, separated bars use 24 points of height in the floating player and 44 in
the expanded player. Geometry is cached until the samples or view size change;
playback updates only the accent progress mask and thin playhead. Hovering shows
a position marker and timestamp, and dragging updates immediately without an
implicit progress animation. The native accessible slider and visible focus
indicator are retained. A click or the first drag event always begins scrubbing.

Only the current song is requested. Concurrent player views share an analysis job;
the last departing subscriber cancels it. A fixed 16,384-frame scratch buffer and
an eight-second analysis budget bound background work. Slow/unsupported files use
a plain progress line that still seeks. No fake waveform is generated. Decoder open
or a blocked filesystem read can exceed that budget before returning. Failures are
remembered briefly to avoid repeated work. Playback errors are never set by analysis.

The cache uses path, size, modification time and an algorithm version. Metadata is
read afresh, avoiding Foundation URL resource-value caches after file changes. Files
changed during analysis are discarded. Memory holds at most 24 waveforms and the
private, disposable disk cache at most 256. Cache failures/corruption fall back to
analysis. Analysis holds its own scoped read access and does not need additional
sandbox privileges.

Tests cover packed integer precision, stereo cancellation, timeline buckets,
endianness, high-aligned/unsigned PCM, float NaN/Infinity, cancellation, time budget,
cache sharing/persistence/corruption/change invalidation/pruning, energy versus
peak envelopes, stereo energy, bounded geometry, global scaling, timestamp safety,
and pointer bounds.
