# Sleep timer

The timer icon beside Repeat in the floating player offers 15, 30, 45, 60, 90, and 120 minutes. Its fixed-size slot stays in place when active; the icon turns pink. Open it to see the pause time, replace the duration, or cancel. Expanded Now Playing has the same shared timer control.

The timer pauses playback without clearing the queue, seeking, or changing device volume. It keeps its deadline across song changes and manual pause/resume. Expiring while paused never starts playback. If a deadline arrives during opening or seeking, the pending pause waits for that operation to finish; cancellation or replacement withdraws it. An EOF/repeat race cannot start the next song after expiry. Playback errors use the existing error surface.

A timer is session-only: quitting cancels it, and it is not restored at launch. One suspended task handles the duration, with no periodic countdown polling. Only an expired timer waiting for a busy playback operation retries briefly until that operation completes or the timer is cancelled.

Validation: 101 tests in 13 suites passed. Five new device-free tests cover pause/position/queue preservation, stale wakeups after cancel or replacement, expiry during opening, cancellation during a busy operation, already-paused playback, EOF with Repeat All, invalid durations, and shutdown. Debug build succeeded. Manual checks verified duration selection, replacing a timer, the displayed deadline, cancellation from expanded Now Playing, shared state, and the floating player at 1100- and 792-point window widths. The timer was cancelled after validation; the existing paused session and volume were preserved. Real-time expiry uses the production sleep task; automated expiry tests inject a controllable wakeup rather than waiting 15 minutes.
