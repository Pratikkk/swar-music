# Playback queue

Player owns an ordered queue, persisted as a listening session. Each insertion gets its own UUID, file URL,
source-folder access URL, display title, subtitle, cached artwork URL, and optional playback error.
Duplicate tracks can appear independently. Library actions resolve a scoped folder
URL; opening each queued track acquires an independent scope for its playback lifetime.

Play Album uses disc number, track number, and title order. Playing an individual
track replaces the queue with the playable tracks currently loaded in its view,
starting at the selected track. Album/group browsing uses the library's loaded page;
use Load More before queuing a larger selection. Files already marked unreadable
by the scanner are excluded from this selection.

Play Next inserts immediately after the current entry. Add to Queue appends. Both
work before playback starts. A standalone Open Audio File clears the old queue,
prepares without autoplay, and becomes the current entry if a successor is added.
The Queue popover shows the current entry and Up Next; upcoming entries can be
removed, reordered by drag, played directly, or cleared. Earlier entries are retained
for Previous. Failed entries remain visible in the queue's failure disclosure.

Next starts the next entry. Previous restarts when more than three seconds have
played, or on the first entry; otherwise it starts the previous entry. Command-right
and Command-left invoke these actions; unmodified arrows still seek five seconds.
Queue mutations and transport changes are disabled during an asynchronous transition.

## Completion and errors

The audio engine reports explicit completion after decoder EOF and ring-buffer drain.
Player consumes completion once, so a short track that ends between UI polls still
advances. Pause, device errors, and seeking to the end while paused do not count as
natural completion. Seek/replay rearms completion. Opening failures are recorded on
the queue entry and skipped in a bounded forward pass. If every remaining entry
fails, playback stops and retains those errors. A device/start or mid-playback error
stops playback rather than trying every track against a failing output device.

Each transition opens a new audio session and restores/configures the device through
the existing engine. Restoration waits for HAL readback before the next session opens,
so delayed restoration cannot overwrite the next track’s requested rate. This is sequential playback with a gap, not gapless playback.
The format chip updates from the decoder and actual device for the new session.

## Verification

Sixteen device-free queue tests use an injected engine to cover selected-track start,
exactly-once EOF advancement, final stop, pause/seek distinction, replay after EOF,
previous/restart, duplicate entries, Play Next, reordering/removal, corrupt-file skip,
standalone open behavior, and blocked edits during asynchronous opens.

A separate opt-in test uses real AUHAL and quiet generated tones. It checks automatic
96 kHz to 44.1 kHz advancement across a corrupt entry, actual source/output rates,
final stop, Repeat One restart, Repeat All wrap back to 96 kHz, and no buffer
underruns. Run it separately from other hardware tests:

```sh
python3 Tools/make_audio_fixtures.py /tmp/swar-queue-audio
SWAR_TEST_QUEUE_FILE=/tmp/swar-queue-audio/quiet-24bit-96k.m4a \
SWAR_TEST_QUEUE_ALTERNATE_FILE=/tmp/swar-queue-audio/quiet-16bit-44k.m4a \
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test \
  --package-path Packages/SwarKit --filter HardwareQueueTests
```

The signed sandboxed app was checked for album play controls, track context commands,
Add to Queue, and the empty/populated Up Next popover. Real queue transitions were
verified in the hardware test; drag gesture behavior has not been manually checked.

## Shuffle and repeat

The player exposes Shuffle and a Repeat menu (Off, All, One). These settings affect
queue order and advancement only; they do not process audio. They carry across playback selections and are saved with the listening session.

Shuffle randomizes only upcoming entries. The current entry and played history stay
in place. Turning Shuffle off restores the remaining original order, retaining new
Play Next/appended entries and excluding removed entries. Playing a new selection
while Shuffle is on preserves the selected starting track and shuffles its successors.
A manual queue reorder becomes the new order to restore; additions retain their
explicit Play Next or append position. Repeat All reuses the current queue order.

Repeat One replays the current track after natural EOF, including a standalone file.
Manual Next still advances. Repeat All wraps from the last entry to the first on EOF
or Next. Repeat Off stops at the end. Each advance tries each candidate at most once,
even when wrapping, so an all-corrupt queue stops. A failed repeat-one reopen can
fall forward to a succeeding entry rather than retrying forever. Device errors stop.

Six additional device-free tests cover shuffle invariants/restoration, edited queues,
repeat-one/manual-next semantics, repeat-all/off boundaries, bounded corrupt-file
wraparound, and standalone repeat. The real AUHAL test also exercises repeat restart
and wraparound. The shuffle/repeat controls compile in the signed Release build;
the new controls have not been manually checked with VoiceOver.

Queue persistence is described in [session restoration](Sessions.md). Media keys and
gapless handoff remain future work.
