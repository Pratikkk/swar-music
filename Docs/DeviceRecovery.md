# Device recovery

Swar distinguishes output/driver failures from decoder failures. A device that
remains in the catalogue with the same numeric ID can still be rebuilt after a
rate change, driver error or wake. Decoding errors do not automatically reopen
hardware. The existing output picker also offers Reconnect Output for manual
recovery, even when a healthy-looking driver needs rebuilding.

Recovery retains the audible URL, queue-entry/playback identity and consumed
position. AUHAL is disposed and rebuilt even if a vanished driver rejects Stop.
Rebuilding starts paused. Before resuming, Swar rechecks current playback intent,
sleep-timer state and the device's stable UID. Shutdown, sleep or device replacement
during a rebuild cannot cause delayed playback. The render callback is unchanged;
HAL work stays on the engine queue and catalogue reads on a utility worker.

Missing devices retain the saved preference. Fallback outputs stay paused, and
reconnecting the preferred device does not resume an unplugged session. No-output
periods retain the song and position; seeks made while disconnected are applied
when output recovery succeeds. Hardware volume writes are disabled while recovery
is needed. Numeric ID reuse is treated as a different device when its UID changes.

Transient failures use the existing two-second output refresh, with exponential
failure delays capped at eight seconds. At most five rebuild attempts are allowed
per minute, including drivers that repeatedly recover then fail. Exhaustion drops
autoplay intent. Topology changes, explicit Play/Reconnect or output selection can
reset the budget. Idle playback does not gain another polling timer.

NSWorkspace willSleep/didWake observers are registered with system media controls
and removed on shutdown. Events run serially so a fast wake cannot overtake sleep
preparation. Sleep cancels continuation work, closes output and saves the session.
Wake rebuilds an opened session. It resumes only if it had been playing, the same
output UID is available, and the sleep timer has not expired. Previously paused or
restored-but-unopened sessions remain paused. Gapless preparation resumes after
successful recovery without changing song identity.

Tests cover same-ID recovery, decoder-error exclusion, paused/playing sleep and
wake, fallback safety, same-ID replug, offline seeks, bounded retries, ID reuse,
rapid notification ordering, observer teardown, expired sleep timers, device changes
during rebuilding, shutdown during rebuilding and empty engine suspension. Tests
post workspace notifications through an isolated NotificationCenter; they do not
sleep the host or require physical unplugging. Manual reconnect is also checked in
the installed app. Physical hardware/OS sleep behavior remains driver dependent.
