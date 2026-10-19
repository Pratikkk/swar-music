# Waveform seek bar

The floating and expanded players show a full-song waveform with live played
progress, a playhead and the existing elapsed/remaining times. Click or drag anywhere
to seek. Left/Right move five seconds; the accessibility representation remains a
native playback-position slider. Existing throttled/coalesced seeking and preview
handoff are retained. Settings → Now Playing → Show song waveform switches back to
the standard slider. This is an amplitude overview, not a live frequency spectrum.

Analysis opens a separate decoder on a utility task. It never reads or modifies
playback's decoder/ring buffer, changes device settings, or processes output PCM.
The waveform contains 512 full-timeline peak buckets, taking the largest magnitude
across channels so opposite phases do not cancel. Integer 8/16/20/24/32-bit and float
32/64-bit PCM layouts are handled, including byte order, signedness and high-aligned
containers. Drawing uses per-song visual normalization; waveform height is not a
calibrated loudness meter. Non-finite samples are ignored.

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
cache sharing/persistence/corruption/change invalidation/pruning, and pointer bounds.
