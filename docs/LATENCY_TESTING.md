# Latency testing plan

**Problem:** with the test rig below, the receiving Mac's metronome sounded about **361 ms late**
compared with the sending Mac's metronome. Setting TC Trigger's offset to −361 ms lined them up
by ear.

**Goal:** find out where those milliseconds actually come from, fix whatever can be fixed at the
source, and end up with an offset that stays correct when the real chain (Broadcast → SDI →
Resi → campus) replaces the test rig.

## The test rig

```
SENDING MAC                                   RECEIVING MAC (TC Trigger)
Ableton: LTC audio clip on a track ─┐         Dante Virtual Soundcard (DVS) in
         + metronome                ├─ Dante ─▶ TC Trigger ── MIDI "TC Trigger" ──▶ Ableton
         └─▶ Dante Virtual Soundcard┘                          (Play/Stop mapped)      │
                                                                                      metronome
                                                                                       │
                                                                     DVS out ◀─────────┘
```

## What we already know (from TC Trigger's logs, 11 Nov)

| Question | Answer | How we know |
|---|---|---|
| Does TC Trigger fire on time? | **Yes.** It sends the note within ~10–15 µs of the moment the cue frame arrives over Dante. | `cue.fired … exact, sent +10 µs from schedule` |
| Was the missing pre-roll the cause? | **No.** It made cues at the very start of a segment fire 4–5 frames late. The `Play` cue was already exact, and adding 4 s of pre-roll didn't change what you heard. | `via catch window, 4–5 frames late`, only on cues at segment start |
| Launch quantization? | **No.** Play is triggered from a stopped transport, which starts immediately. | — |
| Plug-ins or track delay? | **No.** None on the tracks used, and the test uses Ableton's metronome. | checked in Ableton |

So the 361 ms is **outside TC Trigger**: on the sending Mac, in Dante, or in the receiving Ableton.
The tests below separate those.

## Before every test

1. Set **TC Trigger** to:
   - **offset: 0 ms**
   - **catch window: 3**
   - **Verbose: on** (Logs tab)
2. Make sure every LTC segment has **at least 3 seconds of LTC before the cue**.
3. In the **receiving Ableton**, set the start marker / insert point at **1.1.1**, and stop the
   transport before each pass.
4. Write down for **both Macs** (fill in the results sheet at the bottom):
   - Ableton **Settings → Audio**: sample rate, buffer size, and **Overall Latency**
   - **Dante Controller → Device View → Latency** for each DVS
   - the sending session's **tempo**
5. Before each test, add a **Mark** in TC Trigger's Logs tab ("Test 1, pass 1"), so the log
   lines up with your notes.

## Test 1: Is the cue on a beat of the sending session? (no rerouting needed)

**Why:** you're comparing two metronomes. The receiving Ableton counts its beat 1 from the
instant TC Trigger presses Play. If that instant falls *between* beats on the sending Mac, every
receiving click is offset by the same amount. That sounds exactly like latency, but it's the beat
grid. This is the most likely cause.

**The maths (30 fps):** a beat lasts `1800 ÷ BPM` frames.

| BPM | 60 | 72 | 75 | 90 | 100 | 120 | 150 |
|---|---|---|---|---|---|---|---|
| Frames per beat | 30 | 25 | 24 | 20 | 18 | **15** | 12 |

At tempos where this isn't a whole number (e.g. 70 BPM = 25.7 frames), beats don't land on
frame boundaries. Use 120 BPM for testing.

**Example:** the current cue `00:10:04:08` is **128 frames** after `00:10:00:00`. At 120 BPM
that's 8.53 beats, so Play is pressed **267 ms after a sending beat**. Add normal output
latency and you get roughly the 361 ms you heard.

**Steps:**
1. Sending Ableton at **120 BPM**. The LTC clip must:
   - start **exactly on a bar line** (zoom all the way in)
   - have **Warp off**
   - have its **start marker at the very beginning** of the clip
2. Check the LTC file's first frame is `00:10:00:00`. TC Trigger's log shows
   `LTC heard from …`; the first frame is usually reported one frame late, which is normal.
3. Set the TC Trigger cue to a timecode on a beat, e.g. **`00:10:04:00`** (beat 8) or
   **`00:10:04:15`** (beat 9).
4. Play it 3 times and listen.

**Reading the result:**
- **The gap is now small** (sounds like a slight flam, tens of ms): Test 1 was the main cause.
  Continue with Test 3 to measure the real offset.
- **Still about 300+ ms:** the grid wasn't it. Continue with Test 2.

## Test 2: Do the sending Mac's LTC and click leave together?

TC Trigger's calibration tool measures this to the millisecond. Ableton on the receiving Mac
isn't involved.

**Steps:**
1. In the **sending Ableton**, send the metronome to its own Dante channel. The metronome plays
   through the **Cue Out**: in the Master track's mixer, set **Cue Out** to a spare DVS output.
   Alternatively, put a click audio clip on its own track starting exactly at the cue's position.
2. In **Dante Controller**, route that sending channel to a **spare DVS input** on the receiving
   Mac (not the LTC input).
3. In TC Trigger, go to **Settings → Timing → Calibrate Offset…**:
   1. Choose that spare input.
   2. Click **Start**.
   3. **Arm**.
4. Play the LTC segment through the cue 3–5 times.
5. Read the **click +X ms** values. Ignore "suggests" for this test.

**Reading the result:**
- **About 0 ms (within ±5):** the sending Mac sends LTC and click together. The problem is on the
  receiving side (Test 3).
- **A large positive number:** the sending Mac's LTC leaves *later* than its click. Look at the
  LTC clip's position, Warp setting and start marker on the sending Mac, and at its timecode
  value. Fix it **on the sending Mac**, not with TC Trigger's offset.
- **A large negative number:** the LTC leaves *earlier* than the click. Same places to look.

Whatever Test 2 shows belongs to the *sender*. At Broadcast, the LTC must line up with the
timeline the singer follows. Fix it there, so every campus doesn't have to compensate.

## Test 3: How late is the receiving Ableton? (this is the real offset)

This measures "cue frame arrives at the receiving Mac → its Ableton sound leaves the receiving
Mac", which is exactly what TC Trigger's offset should cancel.

**Steps:**
1. In the **receiving Ableton**, set the Master track's **Cue Out** (the metronome) to a spare DVS
   output.
2. In **Dante Controller**, route that receiving-Mac output back to a spare receiving-Mac DVS
   input. If Dante Controller won't let DVS receive its own channel, see the DVS section of
   [LOOPBACK_TEST.md](LOOPBACK_TEST.md). Don't loop through the mixing console.
3. In TC Trigger, open **Calibrate Offset…**, choose that input, click **Start**, and **Arm**.
4. Play through the cue 3–5 times. Stop the receiving transport between passes.
5. Read **click +X ms** and **suggests**. The spread between passes should be under 5 ms.

**Reading the result:**
- **About +20 to +60 ms:** normal. This is Ableton's output latency plus DVS. Click **Apply**;
  the offset becomes about −20 to −60 ms.
- **Much more (100+ ms):** something on the receiving Mac is slow:
  - Check Ableton's **buffer size** (try 256), and the **Overall Latency** you wrote down.
  - Check the **DVS latency** setting.
  - Check whether Ableton takes extra time to start its transport from stop. Compare by
    starting it with the space bar while watching a meter.
- **Big spread** (over 5 ms between passes): something isn't consistent, such as the
  transport not being stopped each time, or the start marker not at 1.1.1.

## Test 4: Does it add up?

Roughly: **what you heard ≈ Test 1 grid offset + Test 2 + Test 3 + Dante latency (each way)**.

If the numbers add up to roughly what you heard by ear, the picture is complete. If there's a big
unexplained remainder, compare **where you're listening**. The sending click and the receiving
click must take equal paths to your ears: the same console, the same headphones, no extra
processing on one of them.

## Final setting

- Fix any **Test 1** (grid) or **Test 2** (sender) problem at the source.
- Set TC Trigger's offset from **Test 3** only. Redo Test 3 on each campus Mac, and whenever
  you change that Mac's interface, Ableton buffer size or sample rate, or DVS latency.
- In the real chain (Broadcast → SDI → Resi → campus), delay *before* the LTC reaches the campus
  Mac is shared with the singer, so it needs no offset.

## Results sheet

| | Sending Mac | Receiving Mac |
|---|---|---|
| Ableton sample rate / buffer | | |
| Ableton Overall Latency | | |
| DVS latency setting | | |
| Sending tempo (BPM) | | — |

| Test | Pass 1 | Pass 2 | Pass 3 | Notes |
|---|---|---|---|---|
| 1: by ear, cue on a beat (gap?) | | | | cue used: |
| 2: sender click vs LTC (ms) | | | | |
| 3: receiver Ableton (ms) | | | | suggested offset: |

## If you want help reading the results

In TC Trigger, go to **Logs → Export Logs…** (last 7 days) and send the zip along with the
results sheet. Your Marks show where each test starts, and Verbose mode records the timing
details (`cue.timing_check`, `cal.measurement`).
