# Smart Crossfade stages

1. Analysis foundation: implemented as an opt-in Analyze Rhythm action in a song's Get Info sheet. A separate utility-priority decoder computes an energy-onset tempo estimate (60–180 BPM), observed beat positions, and half-second RMS bins. A single analysis lane avoids competing analysis decoders. Closing the sheet cancels its request. A versioned private cache uses path, size and modification time; changed files are rejected before publishing results. Cache writes are optional and retention is bounded to 256 entries. Songs over 15 minutes or jobs exceeding their decoding budget are rejected rather than silently sampling part of the song.
2. Transition planner: implemented as an analysis-only policy and a Preview Next Transition button in Get Info for the current queued library song. It tries 16/8/4-beat windows up to the requested length, requires strong profiles and steady local beats, limits cumulative relative beat drift to 70 ms, and bounds overlaps to 2–12 seconds. Incoming audio always starts at zero; its first detected beat is aligned by positioning the outgoing transition. Current playback position is a lower bound on scheduling. Consecutive tracks within the same album/disc remain gapless. Missing or uncertain analysis and incompatible beats produce a short 0.5–2 second track-length-scaled fallback; invalid timing, very short tracks, or missed windows remain gapless. Energy is only a candidate ranking hint, not a vocal detector. Actual mixing remains disabled.
3. Two-stream PCM mixing: pending. Schedule by audio sample time, reserve headroom, handle different sample rates, and preserve seek/queue/device-recovery behavior.
4. Listening validation and opt-in UI: pending. Keep gapless and untouched PCM available; mixing must be clearly distinguished from bit-perfect playback.
5. Optional pitch-preserving tempo matching: separate future work.

## Analysis limits

This first analyzer is an energy/autocorrelation baseline, not a validated general-purpose music beat tracker. Its rhythm-strength score is a periodicity heuristic, not a probability. Half/double tempo, changing tempo, sparse percussion, syncopation, and dense music can mislead it. It does not detect downbeats, time signatures, phrase boundaries, key, or vocals. Do not use it alone to turn on automatic transitions. Evaluate a real-song corpus and detection confidence policies before enabling the planner. No external analysis library or network service is used.

## Initial validation

Synthetic onset tests cover 60/90/120/150/180 BPM with count, timing and ordering assertions. Native PCM click-track tests exercise decode, energy bins, persistent cache reuse, file-change invalidation, cancellation, and time budget handling. Silence, constant envelopes, malformed input and deterministic nonperiodic noise must not invent tempo. These tests do not establish real-music accuracy or audible transition quality. Playback behavior has not been changed by this stage.

## Planner validation

14 planner/rhythm tests pass, including differing beat phases, requested 4/8/16-beat windows, shorter overlaps for tempo drift, half/double tempo rejection, missing/weak analysis, malformed/stale profiles, sparse/irregular beats, late scheduling, and gapless album protection. The package builds with the preview UI. The preview has not been exercised in an installed app; listening and sample-accurate mixing tests belong to the next stage.
