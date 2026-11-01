# TC Trigger

A small macOS menu-bar app that listens to LTC (SMPTE linear timecode) on an audio input and
launches Ableton Live scenes over MIDI when it hears specific frames. It's built for Generation
Church's satellite campuses, where the LTC arrives over Resi alongside the streamed singer.

**Version 1.0.0.** It locks to LTC, fires cues as scheduled MIDI notes through its own virtual
MIDI source "TC Trigger", and logs every fire and miss. It can be armed and controlled from a MIDI
controller, and it runs unattended. See [docs/DESIGN.md](docs/DESIGN.md) for how it works.

Requirements: Apple Silicon Mac, macOS 14 or later. Building needs Xcode and XcodeGen
(`brew install xcodegen`).

## Build (on your Mac)

**One time only**, create the signing certificate. This keeps campus Macs from re-asking for
audio permission after every update:

```bash
./scripts/make-signing-cert.sh
```

Then build:

```bash
./scripts/build.sh
```

The first build after creating the certificate may ask to let `codesign` use the key. Click
**Always Allow**.

This produces `build/TC Trigger.app`. Open it with:

```bash
open "build/TC Trigger.app"
```

If you can't see the menu-bar icon (on a MacBook with a notch it can hide behind the notch when
the menu bar is full), double-click TC Trigger in Applications again and the main window opens.
You can also hold ⌘ and drag other menu-bar icons around to make room.

The app lives in the menu bar (a waveform icon: gray = no lock, blue = locked). Click it, then
**Open TC Trigger…** for the main window. On first launch, macOS asks for audio input
("microphone") access. Click **Allow**, because that's how the app hears the LTC channel.

## Install on a campus Mac

1. On your Mac, make the install zip:

   ```bash
   ./scripts/package.sh
   ```

   This creates `dist/TC-Trigger-<version>.zip` and shows it in Finder.
2. Get the zip onto the campus Mac (USB stick, AirDrop, Google Drive…) and double-click it to
   unzip.
3. Drag **TC Trigger** into the **Applications** folder. If it's an update, quit TC Trigger
   first and replace the old one.
4. **Get past Gatekeeper** (TC Trigger isn't notarized by Apple, so macOS blocks the first launch).
   Do one of these:
   - **System Settings way:** double-click TC Trigger. When macOS says it can't be opened, click
     **Done**. Open **System Settings → Privacy & Security**, scroll down to *"TC Trigger" was
     blocked…* and click **Open Anyway**, then enter the Mac's password and click **Open**.
   - **Terminal way:** paste this into Terminal and press Return, then open TC Trigger normally:

     ```bash
     xattr -dr com.apple.quarantine "/Applications/TC Trigger.app"
     ```

   (Right-click → Open no longer works for this on current macOS.) You only need to do this
   once per downloaded copy.
5. When asked, click **Allow** so TC Trigger can use audio input (that's how it hears the LTC).
   If you clicked Don't Allow: **System Settings → Privacy & Security → Microphone**, turn on TC
   Trigger, then quit and reopen it.
6. Click the menu-bar icon → **Open TC Trigger…** and in **Settings**:
   - type the **campus name**
   - choose the **audio interface and LTC input channel**
   - turn on **Launch TC Trigger at login**
   - set up the MIDI controller, if you use one
7. In **Cues**, click **Import…** and load the cue list you exported.
8. Set up Ableton (below), then **measure the offset**:
   [docs/LOOPBACK_TEST.md](docs/LOOPBACK_TEST.md).

## Set up Ableton

1. Ableton → **Settings → Link, Tempo & MIDI**. In the MIDI Ports list, find **Input: TC Trigger** and
   turn on **Remote** (Track can stay off).
2. In TC Trigger's **Cues** tab, add a cue for each song: name, LTC timecode, MIDI note, channel.
3. In Ableton, enter MIDI Map mode (⌘M), click the song's scene launch button, then click
   **Test Fire** on that cue in TC Trigger. The note is now mapped. Leave MIDI Map mode.
4. Set each song scene's launch quantization to **None**, or set Global Quantization to None.
   Otherwise Ableton waits for the next bar.
5. Click **Arm** in TC Trigger (the menu-bar icon turns green).

When disarmed, cues never send MIDI, but the log still records "Would have fired".

## MIDI controller (optional)

In **Settings → MIDI control**, choose your controller as the **Controller input**. For each action
(Arm/Disarm Toggle, Arm, Disarm, Fire Next Cue, Panic), click **Learn** and press the button.
TC Trigger detects whether the button sends a press and a release, or a single message per press,
so one press never counts twice.

For an LED that shows the armed state, choose the controller under **Feedback output**. Then click
**Learn** next to **Armed LED** and press the button whose light should follow. TC Trigger sends
127 when armed and 0 when disarmed. It re-sends this at launch and whenever the controller reconnects.

- **Fire Next Cue** sends the next enabled cue after the last one fired, right away, even when
  disarmed. It's the manual backup if LTC fails.
- **Panic** sends a note-off for every cue note, sends All Notes Off on all 16 channels, and cancels
  any cue waiting to fire.
- Nothing automatic ever arms TC Trigger. Only you can, with the button or your controller.

## Share a cue list between campuses

In the **Cues** tab, click **Export…** to save the list as a `.json` file. At another campus, click
**Import…** and choose that file. Importing *replaces* the whole list (TC Trigger asks first), and
the log records what was imported. A file with a mistake in it is rejected, with a message naming
the cue that's wrong, and the current list stays as it was.

Cue warnings (⚠️ in the list, hover for details) flag:
- two enabled cues on the same timecode
- two cues sending the same note and channel
- a timecode that can't exist at the detected frame rate
- a cue with no name

## Weekend checklist

- [ ] Menu-bar icon visible. **Blue** means locked to LTC, **green** means armed.
- [ ] Play a short LTC test, or check that the last segment in the **Logs** tab locked at the
      expected frame rate.
- [ ] **Test Fire** the weekend's cues with Ableton stopped. The right scenes light up.
- [ ] Cues for this weekend are **enabled**, and the **Next** cue on the Status tab is the first song.
- [ ] **Arm**. The controller LED, if you have one, lights up.
- [ ] After the service, if anything felt off: **Logs → Mark…** with what happened, then
      **Export Logs** and send the zip.

TC Trigger keeps the Mac awake while armed, so leave it armed for the whole weekend if you like.
It only ever sends MIDI when it hears a cue's timecode.

## Run the tests

```bash
swift test --package-path Core
```

## Make LTC test files

```bash
./scripts/make-test-wavs.sh
```

This creates `TestAudio/<rate>/` for 24, 25, 29.97 DF, 29.97 NDF and 30 fps. Every file has a cue
at **01:00:00:00**:

| File | What it is |
|---|---|
| `01_preroll_5s.wav` | 5 s of LTC before the cue, 25 s total |
| `02_preroll_1s.wav` | only 1 s of pre-roll |
| `03_glitch_at_cue.wav` | the cue frame and the next are silent (codec glitch) — still fires on time |
| `04_dropout_caught.wav` | LTC drops out 10 frames before the cue, returns 2 after — fires via the catch window |
| `05_starts_1s_late_miss.wav` | LTC starts at 01:00:01:00 — must **not** fire; logs a miss |
| `06_no_preroll_miss.wav` | LTC starts exactly on the cue — can't lock in time; must **not** fire |

To make your own, use `ltcgen`:

```bash
swift run --package-path Core ltcgen --fps 29.97df --cue 01:00:00:00 --preroll 5 --length 30 --out mytest.wav
```

## Troubleshooting from Terminal

`ltcmon` listens to an input and prints what it hears, without the app:

```bash
swift run --package-path Core ltcmon --list
```

```bash
swift run --package-path Core ltcmon --device "MOTU 828" --channel 3 --seconds 30
```

## Logs

Everything is written to `~/Library/Logs/TC Trigger/TC-Trigger_YYYY-MM-DD.jsonl`, one JSON
object per line. Files older than 90 days are deleted automatically, and the folder is capped at
500 MB. Important events also appear in Console.app under `church.generation.tctrigger`.

**Logs tab** (main window):
- The live view shows the newest entries first.
- You can filter by level, category, date range, and search text.
- **Highlights:** fires are green, misses and errors red, warnings yellow, and marks blue.
- Click a row to see all its details.
- **Mark…** adds your own note (e.g. "band said Song 2 felt late"), so a reported problem can be
  lined up with the data later.
- **Verbose** adds more detail:
  - LTC signal level once a second
  - decode statistics
  - timing measurements
  - raw MIDI in and out

  It turns itself off after 24 hours.

**Export Logs** (in the Logs tab, or in the menu-bar panel for one click) makes
`TC-Trigger_<Campus>_<date>.zip` on the Desktop and shows it in Finder. It contains:
- the last 7 days of logs (or all 90)
- settings and the cue list
- system info: versions, Mac model, and the audio and MIDI devices present

From Terminal, the same zip can be made with:

```bash
swift run --package-path Core ltcmon --export-logs 7
```

Settings are stored in `~/Library/Application Support/TC Trigger/settings.json`, the cue list in
`cues.json` next to it.

## License notes

TC Trigger includes **libltc** (© Robin Gareus and contributors), licensed under the GNU Lesser
General Public License v3 or later. The complete, unmodified libltc source is in
`Core/Sources/CTCCore/libltc/` together with its license (`COPYING`). You can rebuild TC Trigger
against a modified libltc by editing those files and running `./scripts/build.sh`.
