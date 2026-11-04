#!/usr/bin/env bash
# Capture a clean phone screenshot from the emulator into raw/phone/<theme>/<name>.png
# plus a downscaled preview in work/. Re-asserts demo-mode status bar each time.
#   cap.sh <light|dark> <name>
set -euo pipefail
THEME="$1"; NAME="$2"
DIR="$(cd "$(dirname "$0")" && pwd)"
S=emulator-5554

# Re-assert clean status bar (demo mode resets across app relaunches)
adb -s $S shell settings put global sysui_demo_allowed 1 >/dev/null 2>&1 || true
D(){ adb -s $S shell am broadcast -a com.android.systemui.demo "$@" >/dev/null 2>&1 || true; }
D -e command enter
D -e command clock -e hhmm 1200
D -e command battery -e level 100 -e plugged false
D -e command network -e wifi hide
D -e command network -e mobile show -e level 4 -e datatype lte
D -e command notifications -e visible false

OUT="$DIR/raw/phone/$THEME/$NAME.png"
mkdir -p "$(dirname "$OUT")"
adb -s $S exec-out screencap -p > "$OUT"
convert "$OUT" -resize x1200 "$DIR/work/${THEME}_${NAME}_small.png"
identify -format 'captured %f  %wx%h\n' "$OUT"
