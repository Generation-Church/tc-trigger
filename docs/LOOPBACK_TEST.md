# Measuring and setting the offset (loopback test)

**Goal:** when the LTC cue frame arrives at the Mac, Ableton's sound should leave the interface
at the same moment. The singer's audio from Resi arrives together with the LTC, so the band's
tracks then line up with the singer. Ableton has its own output latency, and its scene launch
adds a little more, so each Mac needs an **offset** (usually a few tens of milliseconds,
negative = fire earlier).

TC Trigger measures this for you with a short loopback cable.

## What you need

- A loopback from one spare **output** to one spare **input** of the same audio device: a short
  cable on a physical interface, or a Dante route with Dante Virtual Soundcard (see below). On a 2-in/2-out interface you can temporarily use output 2 → input 2, as long as the
  LTC is on input 1.
- About 10 minutes, with nobody using the PA. The click is loud.

### With Dante Virtual Soundcard (DVS)

If the LTC and Ableton both use DVS, the "cable" is a Dante route:

1. Pick a spare DVS **transmit** channel for the calibration click (Ableton output) and a spare DVS
   **receive** channel that is *not* the LTC channel.
2. In **Dante Controller**, route that transmit channel to that receive channel.
3. In the steps below, "spare output" means that DVS transmit channel, and "loopback input" means
   that DVS receive channel.

If Dante Controller won't let DVS receive its own channel, don't loop through the mixing console:
its processing delay would be counted as if it were Ableton's, and the suggested offset would be
too large. Use a device that passes audio straight through (a Dante I/O box, or a second DVS
computer) and subtract that device's Dante latency setting from the result.

Re-measure whenever you change the **DVS latency** setting, since it shifts when the LTC arrives.

## One-time Ableton setup

1. Create an audio track called **TC Calibration** and set its output to the spare output that
   the loopback cable is plugged into.
2. Put a short, sharp click at the **very start** of a clip on that track. Any drum hit with a hard
   attack works; trim the clip so the sound starts exactly at its start marker.
3. Put that clip in its own scene called **Calibration** and set the scene's launch quantization to
   **None**.
4. In TC Trigger, add a cue called **Calibration** at the timecode of the LTC you'll play (for the
   test files, **01:00:00:00**). Give it its own note, then MIDI-map that note to the Calibration
   scene in Ableton (⌘M, click the scene, then **Test Fire** in TC Trigger, then ⌘M again).

## Measuring

1. In TC Trigger, open **Settings → Timing → Calibrate Offset…**.
2. Choose the **Loopback input** the cable goes into (not the LTC input) and click **Start**.
3. **Arm** TC Trigger.
4. Play LTC that passes the Calibration cue's timecode, either `TestAudio/<rate>/01_preroll_5s.wav`
   played into the LTC input, or real LTC from Broadcast. The scene launches, the click goes out
   through the cable and comes back in, and TC Trigger shows a line like:

   `1. Calibration   click +38.4 ms (offset was +0) → suggests −38 ms`

5. Stop Ableton and repeat 3–5 times. The measurements should agree within a few milliseconds.
   If the *spread* is more than 5 ms, something is inconsistent: check the clip starts exactly on
   the click and the scene's quantization is None.
6. Click **Apply**. Then play once more: the new measurement should read close to **0 ms**.
7. Click **Done** and switch the Ableton track back to its normal routing (or leave the
   Calibration scene unused). Disable or delete the Calibration cue.

Every measurement and the applied offset are recorded in the log (`cal.measurement`, `cal.applied`).

## Notes

- Measure again if you change the audio interface, Ableton's buffer size or sample rate, or add
  plug-ins with latency on the master or band tracks. Each of these changes Ableton's output
  latency.
- The measurement is from the LTC input to the interface output. If the PA path from Ableton is
  longer than the path from the Resi decoder (e.g. extra digital processing on the band
  channels), nudge the offset by ear afterwards. Use **Mark…** in the Logs tab to note what you
  changed and why.
- Negative offsets need pre-roll: every LTC segment needs at least 2 seconds of LTC before its
  cue, plus the size of the offset.
