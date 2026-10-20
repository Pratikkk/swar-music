# Playback soak checks

Run against the installed Release app, with only one Swar process controlling the
chosen output. Record the build, initial song/position, playing/paused state,
queue order, repeat/shuffle, output and volume. Restore those settings at the end.
Listening history may record the songs played during the test.

## Procedure

1. Play a real queue for at least ten minutes. Leave at least one whole song to
   reach EOF without seeking. Observe automatic next-song identity, position,
   artwork, format and transport state. Keep the output volume unchanged.
2. Seek while playing, pause, verify the position holds, then resume. Inspect the
   expanded player for errors or buffer-underrun warnings.
3. Clear and undo the upcoming queue while the current song plays; verify its
   original upcoming order returns and playback continues.
4. Use Reconnect Output on the current route; verify the same song/output resumes
   without losing the queue. Physical unplug/replug and real OS sleep/wake are
   separate hardware-dependent checks, not inferred from manual reconnection.
5. Browse the collection during playback. Record any automation limitations rather
   than treating unsuccessful gestures as passed checks.
6. Sample the app's process CPU/RSS at ten-second intervals. Compare steady-state
   memory with peaks during opening artwork-heavy views. RSS and sampled CPU do
   not establish leak freedom or a rendering frame-rate guarantee.

Run the complementary deterministic tests without competing output owners:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --package-path Packages/SwarKit \
  --filter 'Gapless|DeviceRecovery|QueueTests|EngineLifetime'
```

The PCM tests assert exact sample order and no inserted silence at compatible
boundaries. The device-recovery tests use isolated engines/notification centres;
they exercise playing/paused wake intent, offline seeks, retries, fallback output
safety and shutdown races without sleeping the host. Neither proves the behaviour
of every physical driver. Audible glitches require listening or loopback capture;
UI progression alone is not proof of click-free output.

## Build 100 validation — 20 October 2026

Tested the installed universal Release app on Apple Silicon/macOS 15.8.1 using
External Headphones. Actual playback ran for 620 seconds, starting at
00:54:09 UTC. This was a bounded interactive soak, including a ten-second pause,
seeks and an intentional output rebuild, rather than an uninterrupted or overnight
run. Only one Swar process owned the playback path.

| Check | Observation |
| --- | --- |
| Playing seek | Tabaah Ho Gaye sought to 330 seconds and continued playing. |
| Automatic next | Aira Gaira (Extended) appeared with its own title/position, still playing. |
| Pause/resume | Position held at 44.380 seconds while paused, then advanced after resume. |
| Queue clear/undo | Kabira was removed from Up Next and restored in its original position; current playback continued. |
| Output rebuild | Reconnect Output retained the song and External Headphones route and resumed playback. |
| Natural EOF | Aira Gaira completed without an end seek and advanced to Kabira from the next album. |
| Mixed lossless sources | The app progressed from 16-bit/44.1 kHz ALAC to 16-bit/44.1 kHz FLAC. Output was shared macOS 32-bit float, shown as Converted. |
| Repeat All | Seeking near Kabira's end followed by EOF wrapped to Ghar More Pardesiya and kept playing. |
| Visible health | No playback error or buffer-underrun warning appeared in the expanded-player observations. The process remained alive. |
| Browsing | Albums rendered while playback advanced. Pointer scrolling failed in automation; a native scroll action returned successfully, but scrolling smoothness was not verified. |
| Recovery regression tests | 77 tests in 7 suites passed, including deterministic PCM boundaries and isolated sleep/wake/device-loss behaviour. |

CPU/RSS were sampled every ten seconds for 600 seconds (61 samples):

- RSS: 152.4 MiB at the first sample, 393.2 MiB peak while browsing, 266.1 MiB
  at the final sample. Memory dropped between peaks; this does not prove absence
  of slow leaks.
- Sampled CPU: 11.7% median, 100.5% peak; the steady-period median after three
  minutes was 11.75%. These process CPU percentages use approximately 100% per
  logical core. UI automation and view changes are included; this is not an
  isolated audio-engine CPU benchmark or a frame-rate measurement.
- Raw local observations: `dist/QA/2026-10-20/playback-soak-resources.csv` and
  `playback-regressions.log` (generated artifacts, not repository source).

Restored Tabaah Ho Gaye paused at 63.53625850340136 seconds, with Aira Gaira then
Kabira upcoming, Shuffle Off, Repeat All, and Home selected. The test issued no
volume writes. The device-wide volume changed externally near the end of the run;
the final value was left in place.

Not verified physically: unplug/replug, actual system sleep/wake, Bluetooth route
changes, other DACs/rates, an overnight run, and audible click/gap analysis through
loopback or listening. No source-code fix or new app build was required by the
observed results.
