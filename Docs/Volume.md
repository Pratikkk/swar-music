# Output volume slider

The compact Now Playing bar has a speaker icon and volume slider beside the progress
row. The expanded player has a wider version below its transport controls. Hover
shows the output name and percentage; accessibility reports percentage, mute state,
or unavailability. The tooltip explains that volume affects other apps on that output.

The controller uses Core Audio's virtual main volume when available, preserving the
relative balance of channel controls. It falls back to the device's main scalar
control. Read-only/fixed-volume outputs keep a disabled slider and direct users to
the output's own controls. There is no fallback that scales Swar's PCM samples.
Driver/device attenuation is still part of the output path; this does not establish
a bit-perfect claim. Raising the slider unmutes the main output when that property
is writable. Devices with a separate, unavailable mute control retain their mute state.

A serial controller reads/writes HAL properties without opening audio or
changing sample rate. Player polls every 500 ms for system volume-key changes. It
targets the device used by the open playback session; before playback it follows the
default output. Switching playback devices disables writes until the new volume is
read. Pending drag updates are coalesced to the newest value, pinned to the displayed
device ID, and never redirected to a different device. Volume errors appear on the
volume control and do not replace track errors or stop playback.

Volume is owned by the output device, not saved in a listening session. Track changes,
restoration, and quitting do not reset it. The current paused preview is left running;
the rebuilt UI becomes active after relaunch.

Verification: three device-free tests cover clamping/nonfinite input, unavailable
controls, error isolation, external device changes, and coalescing. A separate real
HAL test on External Headphones briefly lowered volume and restored the original
value without playing audio. Run explicitly with:

```sh
SWAR_TEST_VOLUME=1 \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path Packages/SwarKit --filter HardwareVolumeTests
```

The full suite has 71 tests. The signed Release build is checked; this slider has not
yet been manually checked in a restarted sandboxed UI. Other DACs, Bluetooth, AirPlay,
and physical mute controls remain untested.
