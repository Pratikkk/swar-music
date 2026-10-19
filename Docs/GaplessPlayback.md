# Gapless playback

Swar automatically prepares the next queue entry and appends its decoded PCM to
the existing ring buffer. The same AUHAL unit keeps running across compatible
track boundaries: no stop/start, device restoration, fade, resampling or inserted
silence. The C render callback and its lock-free, single-producer ring are unchanged.
A render read can contain the last samples of one song and the first samples of
the next song.

Compatibility requires identical PCM sample rate, channel count, precision,
packing, signedness/float representation, byte order and frame/packet layout.
Different source codecs can transition seamlessly when their decoded formats match.
Incompatible formats use the existing normal transition, including output-rate
configuration. Encoded silence inside a file is preserved. Codec delay/padding
handling remains the decoder's responsibility; this feature does not infer trims.

A single utility worker opens and primes at most 200 ms (capped at 16,384 frames)
of one successor. Obsolete queued jobs skip file access. The prepared decoder is
transferred exclusively to the engine queue after preparation completes. Its own
security-scoped read access remains alive through its audible lifetime. No decoder,
allocation, Foundation, device or locking work is added to the render callback.
The existing one-second PCM ring and 4,096-frame producer scratch buffer are retained.

The timeline records each appended boundary in absolute consumed frames. A single
consumer-counter snapshot determines audible identity, source format and position;
decoding ahead never changes the displayed song. Player metadata, queue identity,
waveform and listening counter advance together on the existing refresh cycle.
Repeat One gets a new playback identity even when its queue-entry ID is unchanged.
Repeat All and standalone repeat use the same preparation path.

Seeks discard prepared/queued successors and re-prepare from the new position.
Reordering, removal, clear, enqueue and repeat changes update the successor. If
its PCM was already buffered, the unit briefly stops to rebuild the current tail;
this edit is not guaranteed gapless. An edit racing an already-audible boundary
keeps that audible entry identifiable as the current song. Output switches preserve
the audible identity and withdraw old preparation. Pause and sleep timers stop
both current and queued PCM normally.

If preparation fails, is incompatible, arrives after EOF was published, or misses
the available buffering deadline (including very short songs/late seeks/slow disks),
Swar uses its normal completion/next-file path rather than stalling playback.
Errors encountered decoding a queued successor are deferred until that successor
becomes audible, preserving the previous song's buffered tail. Shutdown invalidates
pending work and stops AUHAL before freeing its PCM ring.

Tests compare complete PCM across a boundary within one render read, ring wrap,
repeated boundaries, signed samples and seeks before/after promotion. They cover
format rejection, cancellation and deferred errors, plus player queue mutations,
repeat modes, metadata handoff without reopening, seek/output re-preparation and
queue edits racing a boundary. An installed-app queue transition is also checked.
