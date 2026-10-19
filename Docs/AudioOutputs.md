# Audio outputs

Use the speaker-device button beside volume in the floating player or the output
name in expanded Now Playing. System Default follows the Mac's default output;
a named device pins Swar to that device without changing the system default.
The choice is saved as a Core Audio UID, rather than a transient numeric device ID.

Switching reopens the current song on AUHAL, restores its position and preserves
play/pause state, queue and artwork. A switch can briefly interrupt audio. Existing
source-rate/physical-format checks still apply: incompatible rates are reported,
not silently resampled. A failed switch attempts to restore the previous output
and does not save the failed preference. If rollback also fails, playback stops
and the error is shown. Hardware volume remains device-wide, with no PCM scaling.

A utility task enumerates living output devices at most every two seconds through
the existing volume refresh task; opening the picker requests a fresh list. No
enumeration runs on the main actor, render thread or playback serialization queue.
Unchanged lists do not invalidate the library. Multiple player views share state.

If a pinned output disappears, Swar pauses before routing to the system default,
retains the saved UID and returns to it when available. Reconnection does not
restart paused playback. System Default follows ordinary default-output changes
while preserving playback, unless the active device itself disappeared. A missing
or failing output leaves the selector available for recovery. Catalogue failures
do not prevent the normal default-output open path from attempting playback.

Tests use an injected catalogue and engine to cover UID persistence across changed
numeric IDs, default routing, disconnect fallback, reconnect, no-output handling,
failed/unavailable selections and position/play-state preservation. Hardware tests
require a real Mac and available devices; no exclusive/hog mode is introduced.
