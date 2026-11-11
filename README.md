# TC Trigger

A small Mac app that listens to LTC (SMPTE linear timecode) on an audio input and sends a MIDI
note to Ableton Live when it hears a specific frame. That launches a song, or presses Play, at
exactly the right moment.

It's built for Generation Church's satellite campuses. Broadcast plays LTC alongside the streamed
singer, and each campus's Ableton Mac runs TC Trigger, so the local backing tracks start in sync
with the singer. It works with any audio interface, including Dante Virtual Soundcard. It stays
out of the way the rest of the time and runs unattended.

**Download:** [latest release](https://github.com/Generation-Church/tc-trigger/releases/latest).
**Needs:** an Apple Silicon Mac with macOS 14 or later.

## Contents

- [Install](#install)
- [Set up](#set-up)
- [Updates](#updates)
- [Using it](#using-it)
- [Weekend checklist](#weekend-checklist)
- [Troubleshooting](#troubleshooting)
- [For maintainers](#for-maintainers)

## Install

1. Download `TC-Trigger-<version>.zip` from the
   [latest release](https://github.com/Generation-Church/tc-trigger/releases/latest) and
   double-click it to unzip.
2. Drag **TC Trigger** into the **Applications** folder.
3. **Get past Gatekeeper.** TC Trigger isn't notarized by Apple, so macOS blocks the first launch.
   Do one of these:
   - **System Settings:** double-click TC Trigger. When macOS says it can't be opened, click
     **Done**. Open **System Settings → Privacy & Security**, scroll down to *"TC Trigger" was
     blocked…*, click **Open Anyway**, enter the Mac's password, and click **Open**.
   - **Terminal:** paste this and press Return, then open TC Trigger normally:

     ```bash
     xattr -dr com.apple.quarantine "/Applications/TC Trigger.app"
     ```

   You only do this once. Updates installed from inside the app don't need it.
4. When asked, click **Allow** so TC Trigger can use audio input. That's how it hears the LTC.
   If you clicked Don't Allow: open **System Settings → Privacy & Security → Microphone**, turn on
   TC Trigger, then quit and reopen it.

TC Trigger has a **Dock icon** and a **menu-bar icon**:

| Icon | Meaning |
|---|---|
| gray | not locked to LTC |
| blue | locked |
| green with a bolt | armed |
| yellow flash | a cue just fired |

Click the Dock icon to open the main window. On a MacBook with a notch, the menu-bar icon can
hide behind the notch when the menu bar is full; the Dock icon always works.

## Set up

### TC Trigger

In the main window, open **Settings**:
- **Campus name.** It appears in every log line, so exported logs show which Mac they came from.
- **Audio input.** Choose the device (e.g. *Dante Virtual Soundcard*) and the channel that
  carries the LTC. The **Status** tab should show the timecode and **LOCKED** while LTC plays.
- **Launch TC Trigger at login.** Turn this on for campus Macs.
- **MIDI controller**, if you use one (see [MIDI controller](#midi-controller-optional)).

Then, in **Cues**, add a cue for each song, or click **Import…** to load a list exported at
another campus.

### Ableton

1. **Settings → Link, Tempo & MIDI**. In the MIDI Ports list, find **Input: TC Trigger** and turn
   on **Remote**.
2. Press **⌘M** (MIDI Map mode). Click what the cue should trigger: a scene's launch button, or
   the transport's Play button. Then click **Test Fire** on that cue in TC Trigger. Press **⌘M**
   again to leave MIDI Map mode.
3. If you trigger **scenes** while the transport is already running, set their launch
   quantization (or Global Quantization) to **None**. Otherwise Ableton waits for the next bar.
4. In TC Trigger, click **Arm**.

### The offset

TC Trigger fires the moment the cue frame arrives. Ableton then takes a little time to make
sound. The **offset** (Settings → Timing) makes TC Trigger fire that much earlier: usually a
few tens of milliseconds, negative = earlier. Measure it once per Mac:
- **Guide:** [docs/LOOPBACK_TEST.md](docs/LOOPBACK_TEST.md), using the built-in **Calibrate
  Offset…** tool.
- **If the delay seems far too big:** [docs/LATENCY_TESTING.md](docs/LATENCY_TESTING.md).

### What the LTC needs

- **Pre-roll:** each LTC segment must start at least **2 seconds before its first cue**, plus the
  size of any negative offset. TC Trigger needs a few frames to lock, and it predicts the cue
  from the frames before it. LTC that starts *on* the cue can't fire on time; it's logged as a
  miss or a late "catch window" fire.
- **Frame rate:** 24, 25, 29.97 drop-frame, 29.97 non-drop or 30, detected automatically.
- **Level:** anywhere from about −40 to 0 dBFS works. The Status tab shows the LTC level.

## Updates

TC Trigger checks for a new version once a day (**never while armed**, so no window can appear
during a service), and whenever you click **Check for Updates…** in the menu-bar panel or in
**Settings → Updates**. When there is one, it shows what's new. **Install Update** replaces the
app and relaunches it with the same settings, cue list and armed state. Nothing installs without
someone clicking.

## Using it

### Arming

- **Disarmed:** cues never send MIDI; the log records "Would have fired".
- **Armed:** cues fire. The Mac is kept awake while armed (the display can still sleep).
- Nothing automatic ever arms TC Trigger. Only a person can, with the button or a MIDI controller.

### Cues

Each cue has a name, a timecode (HH:MM:SS:FF), a MIDI note, channel and velocity, and an on/off
switch.
- **Notes:** type the number or pick the name (C3 = 60, as in Ableton).
- **Test Fire:** sends a cue's note immediately, armed or not.
- **Sorting and saving:** cues sort by timecode and save automatically.
- **Warnings (⚠️):** flag two cues on the same timecode, the same note and channel used twice,
  a timecode that can't exist at the detected frame rate, or a cue with no name.

**Sharing a list:** click **Export…** in the Cues tab, then **Import…** at another campus.
Importing replaces the whole list, after asking. A file with a mistake is rejected with a message
naming the bad cue, and the current list stays as it was. Ableton mappings use the **note**, so
every campus should map the same notes to the same songs.

### If the exact cue frame is lost

A codec glitch can drop the cue frame. TC Trigger still fires if LTC comes back within the
**catch window** (Settings → Timing, default 3 frames), and logs it as "catch window, N frames
late". Later than that, it never fires. LTC that stops never triggers anything.

### MIDI controller (optional)

In **Settings → MIDI control**, choose the controller as **Controller input**. Then click
**Learn** next to each action and press the button you want for it:
- **Arm/Disarm Toggle**, **Arm**, **Disarm**
- **Fire Next Cue:** sends the next enabled cue right away, even when disarmed. This is your
  manual backup if LTC fails.
- **Panic:** sends note-offs for every cue note and All Notes Off on all channels, and cancels
  any cue waiting to fire.

TC Trigger works out whether each button sends a press and a release or a single message, so one
press never counts twice. For an LED that shows the armed state, choose the controller under
**Feedback output** and **Learn** the **Armed LED** button.

## Weekend checklist

- [ ] TC Trigger is running (Dock icon). The Status tab shows the right **audio input**.
- [ ] Play a short LTC test: **LOCKED**, at the expected frame rate.
- [ ] **Test Fire** the weekend's cues with Ableton stopped. The right things start.
- [ ] This weekend's cues are **enabled**, and **Next** on the Status tab is the first song.
- [ ] **Arm.** The icon turns green, and the controller LED (if any) lights.
- [ ] After the service, if anything felt off: **Logs → Mark…** describing what happened, then
      **Export Logs** and send the zip.

## Troubleshooting

**Logs tab:**
- newest entries first; filter by level, category, date and text
- fires in green, misses and errors in red, warnings in yellow, your Marks in blue
- click a row for full details
- **Verbose** adds signal levels, timing measurements and raw MIDI. It turns itself off after 24
  hours.

**Export Logs** (Logs tab, or one click in the menu-bar panel) saves
`TC-Trigger_<Campus>_<date>.zip` to the Desktop. It contains the logs, settings, the cue list,
and the audio and MIDI devices present. Send that zip when asking for help.

| Symptom | Look at |
|---|---|
| No timecode on the Status tab | The audio input and channel in Settings. Is LTC actually arriving? (input level meter) Is Dante connected? |
| "Waiting for …" under Audio | The device is unplugged or Dante isn't running. TC Trigger reconnects by itself when it's back. |
| A cue fired late ("catch window") | The LTC started too close to the cue. Add pre-roll. |
| A cue was MISSED | The log line says why. Usually the LTC started after the cue, or had too little pre-roll for the offset. |
| Ableton reacts late | Its launch quantization, then the offset ([LOOPBACK_TEST.md](docs/LOOPBACK_TEST.md), [LATENCY_TESTING.md](docs/LATENCY_TESTING.md)) |
| Can't find the window | Click the Dock icon, or double-click TC Trigger in Applications. |

**Where TC Trigger keeps its files:**
- Logs: `~/Library/Logs/TC Trigger/`, one file per day, kept 90 days
- Settings and cue list: `~/Library/Application Support/TC Trigger/`

---

## For maintainers

Everything below is for building and publishing TC Trigger from the source code. Installing and
using it doesn't need any of this.

**Requirements:** Xcode, and XcodeGen (`brew install xcodegen`).

**How it works:** [docs/DESIGN.md](docs/DESIGN.md) covers threads, timing and firing rules.

### Build

```bash
./scripts/build.sh
```

This builds `build/TC Trigger.app`.

**On the Mac you publish releases from**, do this once first:
1. Create the code-signing certificate. Installed copies only accept updates signed by the same
   certificate, and it keeps each Mac's audio permission across updates.

   ```bash
   ./scripts/make-signing-cert.sh
   ```

2. Create the update-signing key, and back it up when asked.

   ```bash
   ./scripts/setup-updates.sh
   ```

Without these, builds are signed ad-hoc and can't publish updates. That's fine for local testing.

### Publish a release

```bash
./scripts/release.sh 1.2.0 "What changed"
```

[docs/RELEASING.md](docs/RELEASING.md) covers what this does, dry runs, and recovering the keys.

### Tests

```bash
swift test --package-path Core
```

### Developer tools

- **LTC test files:** `./scripts/make-test-wavs.sh` creates `TestAudio/<rate>/` for every frame
  rate, each with a cue at 01:00:00:00:

  | File | Expected behaviour |
  |---|---|
  | `01_preroll_5s.wav` | fires exactly on time |
  | `02_preroll_1s.wav` | fires on time at offset 0 (too little pre-roll for big negative offsets) |
  | `03_glitch_at_cue.wav` | the cue frame and the next are silent, and it still fires on time |
  | `04_dropout_caught.wav` | fires via the catch window, 2 frames late |
  | `05_starts_1s_late_miss.wav` | must **not** fire; logs a miss |
  | `06_no_preroll_miss.wav` | must **not** fire; logs a miss |

  Custom files, including a stereo click for testing calibration:

  ```bash
  swift run --package-path Core ltcgen --fps 29.97df --cue 01:00:00:00 --preroll 5 --length 30 --out mytest.wav
  ```

- **`ltcmon`** listens to an input and prints what it hears, without the app. It can also make
  the log export zip:

  ```bash
  swift run --package-path Core ltcmon --list
  ```

  ```bash
  swift run --package-path Core ltcmon --device "Dante Virtual Soundcard" --channel 1 --seconds 30
  ```

  ```bash
  swift run --package-path Core ltcmon --export-logs 7
  ```

## License notes

TC Trigger includes **libltc** (© Robin Gareus and contributors), licensed under the GNU Lesser
General Public License v3 or later. The complete, unmodified libltc source is in
`Core/Sources/CTCCore/libltc/` together with its license (`COPYING`). You can rebuild TC Trigger
against a modified libltc by editing those files and running `./scripts/build.sh`.

Updates use [Sparkle](https://sparkle-project.org) (MIT license).
