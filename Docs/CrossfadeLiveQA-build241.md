# Build 241 live crossfade smoke test

Date: 2026-10-25

A locally signed sandboxed copy of build 241 was tested as `catto.swar.trashqa`, using the existing disposable QA library. The production app's library and preferences were not edited during this test. Output was External Headphones; device volume was left unchanged.

- Set Short (4 beats), quit completely, relaunch, and reopen Settings: Short persisted and Smart Crossfade remained enabled.
- Started Crossfade One (12-second stereo ALAC, 44.1 kHz) from its artwork play control in Songs, followed by Crossfade Two (12-second stereo ALAC, 48 kHz), in different albums.
- Expanded Now Playing showed Smart Crossfade / Processed audio. Short advanced to Crossfade Two while playback remained active, with the original 48 kHz source and converted Float32 44.1 kHz output. Observed incoming position 7.276 seconds; paused at 10.968 seconds and sought to 3 seconds successfully.
- Repeated from the first fixture with Long (16 beats). Crossfade Two was observed playing at 10.258 seconds with converted output; the queue subsequently continued into Lyrics Motion QA. Pause and seek to 5 seconds succeeded.
- Switched Smart Crossfade off: the length picker became disabled and retained Long. Re-enabled it, restored Balanced (8 beats), verified the selection, and quit the QA app.
- No visible playback error, stop at the first-to-second boundary, or crash was observed.

Limits: accessibility observations are sparse snapshots, not sample-accurate measurements. The observed positions do not establish exact overlap duration or beat alignment. Short and Long received live transition smoke coverage in this run; Balanced received UI coverage, with live build-240 coverage recorded in SmartCrossfade.md. Audio was not captured or independently listened to, so this does not certify absence of clicks, perceived loudness, or musical quality. Hardware unplug/replug and sleep/wake were not tested here. Automated planner and PCM tests provide the precise beat-window and sample-output checks separately.
