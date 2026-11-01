# TC Trigger — Design

Approved 2026-11-01. This is the reference for how TC Trigger works and why.

## Purpose

Each satellite campus plays backing tracks from Ableton Live in sync with a singer streamed from
Broadcast over Resi. Broadcast plays pre-made LTC (SMPTE linear timecode) segments on an audio
channel that rides the SDI feed, so the LTC arrives with exactly the same delay as the video. TC
Trigger runs on each campus's Ableton Mac, listens to that LTC, and when it hears a cue frame it
sends a MIDI note to Ableton to launch the song's scene. It's used for 1–2 songs a weekend and
must otherwise stay out of the way.

## Decisions

| Question | Decision |
|---|---|
| State at launch | Restore the last armed/disarmed state (logged with source "app launch"). |
| "Manual disarm is never overridden" | Nothing automatic ever arms. A person pressing a learned MIDI **Arm** button is a manual action and may arm. |
| Ableton scene launch | Scenes fired by TC Trigger must launch with quantization **None**. |
| Repo | Private, `Generation-Church/tc-trigger`. |
| Build system | Swift package (`Core/`) for all logic + XcodeGen (`project.yml`) for the app. |

## Layout

```
Core/                      Swift package — everything except the UI
  Sources/CTCCore/         C: vendored libltc + tc_core.c (the real-time audio callback, SPSC ring)
  Sources/TCTriggerKit/    Swift logic: Audio, LTC, Engine, Logging, Settings (later: Cues, MIDI, System)
  Sources/ltcgen/          CLI: make LTC test WAVs
  Sources/ltcmon/          CLI: listen to an input and print LTC events (troubleshooting)
  Tests/TCTriggerKitTests/ unit tests (swift test)
App/TCTrigger/             SwiftUI menu-bar app
project.yml                XcodeGen recipe for the app
scripts/                   build.sh, make-test-wavs.sh
```

## Threads

| Thread | Job | Rules |
|---|---|---|
| Core Audio I/O (real-time), C | Render the selected channel, peak meter, feed libltc, push decoded frames + host time into an SPSC ring | No allocation, locks, logging, Swift |
| Engine (`userInteractive` serial queue, 2 ms timer) | Drain ring, lock state machine, rate detection, timing model, (M2) cue engine; owns live state | Single owner of state |
| Fire scheduler (M2, time-constraint priority) | `mach_wait_until` the target host time, send note-on; note-off 100 ms later | Does nothing else |
| Log queue (utility) | Format JSON, write files, mirror to os.Logger | Never touched by real-time code |
| Main | UI at ~30 fps from engine snapshots | |

## Timing

- libltc reports each frame's start as a stream sample index. The audio callback's
  `AudioTimeStamp.mHostTime` maps that to host time: `host = bufferHost + (frameStart − bufferStart) × ticksPerSample`.
  Unit tests show frame starts accurate to < 0.3 ms at 44.1/48/96 kHz.
- `TimingModel` fits a least-squares line through recent (frame index, host time) pairs. Its slope
  is the real frame period; it predicts the start time of any upcoming frame.
- (M2) ~150 ms (plus any negative offset) before a cue, the engine predicts the cue frame's host
  time, adds the offset, and hands it to the fire scheduler. Scheduling is done by TC Trigger itself,
  not by CoreMIDI timestamps, because receivers may ignore future timestamps on virtual sources.

## Lock

- Lock: 5 consecutive frames, each exactly +1 in frame index and ~1 frame period apart.
- Rate: 24/25/30-class from the measured spacing (cross-checked with frame numbers); drop-frame
  flag → 29.97 DF; otherwise 30-class starts as provisional 30 and is decided 29.97 NDF vs 30
  after ~1 s of measured period.
- While locked, a frame must land where the model predicts; up to 3 skipped frames are tolerated
  (counted as dropped). Anything else is a jump → unlock and re-acquire.
- Lost lock: no frame for 4 frame periods + 50 ms.
- Quick relock: after signal loss (not a jump), one frame that lands exactly where the old lock
  predicts (within 2 s) relocks immediately — this lets the catch window rescue a codec glitch.
- Segment: continuous LTC with no gap > 1 s; logged with start, end, duration, frame count.

## Cue firing rules (M2)

For each enabled cue at frame C with catch window N (default 3):
- **Scheduled hit:** locked and approaching C → fire at predicted time of C + offset.
- **Catch:** no scheduled hit, and timecode first heard / relocked at a frame in [C, C+N] → fire
  immediately; logged as "catch window, k frames late".
- **Miss:** LTC first heard past C+N (within 30 s of the cue), or passed C without lock → no MIDI,
  log a miss with the reason.
- Fires once per pass. Re-arms after ~1 s without LTC, when timecode moves past C+N, or when it
  goes back before where it was when the cue fired. (Frames before C are still decoded just after
  an on-time fire, so "timecode < C" alone must not re-arm; a unit test covers this.)
  Firing requires *entering* the window, so re-arming while past it can't cause a late fire.
- A pending schedule is withdrawn if no LTC frame has arrived for 3 frame periods + 30 ms before
  its fire time ("LTC stopped just before the fire time"). A 1–2 frame glitch at the cue still fires.
- LTC that *starts* after the cue can never be caught: lock alone takes 5 frames. The catch window
  covers dropouts in LTC that was already running.
- Disarmed: same logic, logs "would have fired". Lost LTC never sends anything.
- LTC segments need pre-roll of at least 2 s before each cue (lock + up to 500 ms negative offset).

## MIDI (M2/M4)

- Virtual source "TC Trigger" for cue notes only. Note-on, then note-off ~100 ms later.
- Panic: note-offs for every cue-list note on its channel, plus CC 123 on all 16 channels.
- MIDI Learn records whether a control is momentary (press + release) or single-message, so one
  press never triggers twice (250 ms debounce for single-message controls).
- Feedback: 127 armed / 0 disarmed to the chosen destination; re-sent on launch and reconnect.

## Logging

- `~/Library/Logs/TC Trigger/TC-Trigger_YYYY-MM-DD.jsonl`, one JSON object per line:
  `ts` (local, ms, with UTC offset), `lvl`, `cat`, `evt` (stable code like `ltc.lock`), `campus`,
  `run` (one per launch), `msg`, `f` (structured fields).
- Info and above are mirrored to os.Logger (subsystem `church.generation.tctrigger`).
- Real-time code never logs; the engine summarises counters once a second.
- (M5) Verbose turns itself off after 24 h; retention 90 days + 500 MB cap; viewer with filters
  and Mark; one-click export zip to the Desktop.

## Milestones

1. **M1** Audio input, libltc decode, lock, rate detection, timecode display, logging foundation,
   settings, `ltcgen` + `ltcmon`, unit tests. ✓
2. **M2** Cue engine, scheduled MIDI via virtual source, firing-logic unit tests, basic cue
   table, Arm toggle, offset and catch-window settings. ✓
3. **M3** Cue list UI (duplicate, delete with confirmation, context menu, warnings, next-cue
   marker), import/export JSON with per-cue error messages and logging. ✓
4. **M4** Armed state, Fire Next, Panic, MIDI Learn, LED feedback, menu-bar states. ✓
   Fire Next sends regardless of armed state (deliberate operator action, like Test Fire) and
   counts as that cue's fire for the pass. Panic also cancels pending scheduled fires.
5. **M5** Full logging: verbose, viewer, Mark, export, retention.
6. **M6** Reliability (App Nap, sleep, launch at login, stable signing), README install steps,
   loopback offset procedure.
