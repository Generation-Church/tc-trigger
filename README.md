# TC Trigger

A small macOS menu-bar app that listens to LTC (SMPTE linear timecode) on an audio input and
launches Ableton Live scenes over MIDI when it hears specific frames. It's built for Generation
Church's satellite campuses, where the LTC arrives over Resi alongside the streamed singer.

**Status:** Milestone 1 of 6. It hears, decodes, locks to and displays timecode, with logging.
Cues and MIDI arrive in M2. See [docs/DESIGN.md](docs/DESIGN.md) for how it works.

Requirements: Apple Silicon Mac, macOS 14 or later. Building needs Xcode and XcodeGen
(`brew install xcodegen`).

## Build

```bash
./scripts/build.sh
```

This produces `build/TC Trigger.app`. Open it with:

```bash
open "build/TC Trigger.app"
```

The app lives in the menu bar (a waveform icon: gray = no lock, blue = locked). Click it, then
**Open TC Trigger…** for the main window. On first launch, macOS asks for audio input
("microphone") access. Click **Allow**, because that's how the app hears the LTC channel.

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
| `03_glitch_at_cue.wav` | the cue frame and the next are silent (codec glitch) |
| `04_starts_2_frames_late.wav` | LTC starts at 01:00:00:02 (inside the catch window) |
| `05_starts_1s_late.wav` | LTC starts at 01:00:01:00 (too late — must not fire) |

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

`~/Library/Logs/TC Trigger/TC-Trigger_YYYY-MM-DD.jsonl`, one JSON object per line. The **Log**
tab shows recent events live. Important events also appear in Console.app under the subsystem
`church.generation.tctrigger`.

Settings are stored in `~/Library/Application Support/TC Trigger/settings.json`.

## License notes

TC Trigger includes **libltc** (© Robin Gareus and contributors), licensed under the GNU Lesser
General Public License v3 or later. The complete, unmodified libltc source is in
`Core/Sources/CTCCore/libltc/` together with its license (`COPYING`). You can rebuild TC Trigger
against a modified libltc by editing those files and running `./scripts/build.sh`.
