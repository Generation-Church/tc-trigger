#!/bin/bash
# Makes a set of LTC test WAV files in ./TestAudio (one folder per frame rate).
# Every file has a cue at 01:00:00:00.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "Building ltcgen…"
swift build --package-path Core -c release --product ltcgen >/dev/null
LTCGEN="Core/.build/release/ltcgen"

OUT="TestAudio"
mkdir -p "$OUT"
CUE="01:00:00:00"

for FPS in 24 25 29.97df 29.97ndf 30; do
  D="$OUT/$FPS"
  mkdir -p "$D"
  # Normal: 5 s of pre-roll before the cue, 25 s of LTC.
  "$LTCGEN" --fps "$FPS" --cue "$CUE" --preroll 5 --length 25 --out "$D/01_preroll_5s.wav"
  # Short pre-roll: 1 s (fine at offset 0, too short for big negative offsets).
  "$LTCGEN" --fps "$FPS" --cue "$CUE" --preroll 1 --length 10 --out "$D/02_preroll_1s.wav"
  # Codec glitch: the cue frame and the next one are silent.
  "$LTCGEN" --fps "$FPS" --cue "$CUE" --preroll 5 --length 15 --dropout "$CUE"x2 --out "$D/03_glitch_at_cue.wav"
  # LTC starts 2 frames after the cue (inside the default catch window of 3).
  "$LTCGEN" --fps "$FPS" --start 01:00:00:02 --length 10 --out "$D/04_starts_2_frames_late.wav"
  # LTC starts 1 s after the cue (past the window: must NOT fire, must log a miss).
  "$LTCGEN" --fps "$FPS" --start 01:00:01:00 --length 10 --out "$D/05_starts_1s_late.wav"
done

echo
echo "Test files are in $OUT/"
