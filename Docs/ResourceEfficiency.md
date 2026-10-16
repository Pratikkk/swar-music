# Resource efficiency and lifecycle checks

The audio producer retains its 10 ms cadence during playback. Its dispatch timer
is parked at a distant deadline when there is no playing session, including
pause, end-of-track, failure, and shutdown. It is rearmed on resume. The library
window's 200 ms playback polling task also exists only while playing. Hardware
volume monitoring and periodic session persistence remain available while paused.

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
