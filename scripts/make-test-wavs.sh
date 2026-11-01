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

rm -rf "$OUT"
for FPS in 24 25 29.97df 29.97ndf 30; do
  D="$OUT/$FPS"
  mkdir -p "$D"
  case "$FPS" in   # the frame 10 frames before the cue
    24) TEN_BEFORE="00:59:59:14" ;;
    25) TEN_BEFORE="00:59:59:15" ;;
    *)  TEN_BEFORE="00:59:59:20" ;;
  esac
  # Normal: 5 s of pre-roll before the cue, 25 s of LTC.
  "$LTCGEN" --fps "$FPS" --cue "$CUE" --preroll 5 --length 25 --out "$D/01_preroll_5s.wav"
  # Short pre-roll: 1 s (fine at offset 0, too short for big negative offsets).
  "$LTCGEN" --fps "$FPS" --cue "$CUE" --preroll 1 --length 10 --out "$D/02_preroll_1s.wav"
  # Codec glitch: the cue frame and the next one are silent. Still fires exactly on time.
  "$LTCGEN" --fps "$FPS" --cue "$CUE" --preroll 5 --length 15 --dropout "$CUE"x2 --out "$D/03_glitch_at_cue.wav"
  # Dropout from 10 frames before the cue until 2 frames after: fires via the catch window, 2 frames late.
  "$LTCGEN" --fps "$FPS" --cue "$CUE" --preroll 5 --length 15 --dropout "$TEN_BEFORE"x12 --out "$D/04_dropout_caught.wav"
  # LTC starts 1 s after the cue: must NOT fire, must log a miss.
  "$LTCGEN" --fps "$FPS" --start 01:00:01:00 --length 10 --out "$D/05_starts_1s_late_miss.wav"
  # LTC starts exactly on the cue with no pre-roll: can't lock in time, must NOT fire (miss).
  "$LTCGEN" --fps "$FPS" --start "$CUE" --length 10 --out "$D/06_no_preroll_miss.wav"
done

echo
echo "Test files are in $OUT/"
