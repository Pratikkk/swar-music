# Live playback sliders (build 84)

The floating and expanded player share a seek control. Labels and the slider thumb
follow the pointer immediately. While dragging, the control sends the latest changed
position at most once per 120 ms plus the time needed for the preceding seek. On
release it submits the final position immediately. Player's existing pending-seek
coalescing prevents overlapping decoder operations. An explicit seek into the final
50 ms is deferred until release; ordinary playback can still reach natural EOF.

Volume uses the same local preview during dragging, with a visible percentage and
hardware updates paced at 60 ms plus write latency. It writes device-wide volume,
without processing PCM. The final release value is submitted immediately. No extra
writes are sent when the pointer remains at the same value.

Both controls hold their latest preview while asynchronous operations settle. Stale
results cannot overwrite a newer drag, and device/song changes discard obsolete
requests. Keyboard and accessibility adjustments also submit immediately. Hardware
volume may quantize the chosen percentage; once the final write settles, the display
shows the actual value. Failed seeks similarly return to the engine's actual position.

State regressions cover live writes during dragging, release with delayed/coalesced
confirmation, binding updates arriving before editing begins, newer drags, rejected
operations, unavailable controls and changed tracks/devices.
