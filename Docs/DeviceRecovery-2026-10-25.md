# Device recovery validation — 25 October 2026

## Current-source regression suite

Source: c4c8c4a on main. Ran:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --package-path Packages/SwarKit --skip-update --filter 'DeviceRecovery|OutputRouting|OutputDeviceMonitor|OutputDeviceSelection|EngineLifetime'
```

PASS: 34 tests across six suites. Raw log: `dist/QA/2026-10-25/device-recovery/tests.log`.

Coverage includes same-ID driver failure, position/playing-state recovery, decoder failures not triggering device recovery, playing/paused sleep-wake intent, missing headphones never autoplaying on fallback speakers, paused removal/replug, numeric device-ID reuse, bounded retry/backoff, serialized rapid sleep/wake, expired sleep timer, device changes during rebuild, shutdown during recovery, device monitor lifetimes, saved UID selection, exclusive-choice preservation, and synchronous engine cleanup. Simulated hardware and injected notifications are used where appropriate; these are not physical unplug/sleep tests.

## Installed-app smoke test

Installed app: /Applications/Swar.app, version 1.0.0 build 141, macOS 15.8.1. This build predates current main and its smoke results must not be reported as GUI verification of current main.

Initial state: Home; Aye Bachchu by Suzanne, Ghajini; paused/restored at 48.85725623582766 seconds; Shuffle Off; Repeat One; External Headphones; exclusive off. Queue: 381 upcoming tracks, beginning Kaise Mujhe, Behka, Latoo, Barso Re, Tere Bina.

- PASS: Reconnect Output while playing preserved song and External Headphones route; transport remained Pause and position advanced from approximately 55.60 to 57.98 seconds, without an observed error.
- PASS: paused at 67.59575963718821 seconds, then Reconnect Output; position and Play transport remained unchanged, with no autoplay.
- PASS: queue count and first five upcoming entries matched after recovery. No queue editing occurred; full remaining order was not independently enumerated.
- PASS: restored Home, original song paused at exactly 48.85725623582766 seconds, Shuffle Off, Repeat One, original route and exclusive setting. No volume or system-output settings were written.

## Not physically validated

No actual device unplug/replug, Bluetooth disconnect/reconnect, real host sleep/wake, alternative DAC/rate, or audible/loopback continuity check was performed. Manual reconnect exercises rebuilding an available output; it does not prove recovery from missing hardware. Current main also requires an installed-build smoke pass before release. No source-code defect was established by these checks; no recovery implementation was changed.
