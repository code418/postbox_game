#!/usr/bin/env bash
# Build the App Store Connect iPhone screenshot set (6.9", 1320x2868).
#
# Source per shot, in order of preference:
#   1. raw/ios/<theme>/<name>.png  - a genuine iPhone capture (TestFlight build;
#      redact PII first, e.g. leaderboard names). Used as-is.
#   2. marketing/phone/<theme>/<name>.png - the existing Play final: the app
#      screen is lifted out of its frame and the Android status bar and gesture
#      bar are painted over, so no other platform's chrome reaches the listing
#      (App Review guideline 2.3.10).
#
#   build_appstore.sh [light|dark]     (default: light)
set -euo pipefail
cd "$(dirname "$0")"
THEME="${1:-light}"
OUT_DIR="marketing/appstore/iphone_6.9/$THEME"
mkdir -p "$OUT_DIR" work

# "name|caption" - same narrative order as the Play set (build_finals.sh).
SHOTS=(
  "01_claim_initial|Stand close. Tap. Claim."
  "02_nearby_results|Postboxes worth points, nearby"
  "03_fuzzy_compass|Hints, not directions"
  "04_claim_quiz|Name the royal cypher"
  "05_claimed|Rarer boxes, bigger scores"
  "06_leaderboard|Climb the leaderboards"
  "07_route_live|Where now, postie?"
  "08_history_map|Every pin, a place you've been"
)

# Device screen inside a 1080x1920 Play final (see frame.sh "phone").
DX=207; DY=424; DW=666; DH=1480
STATUS_H=73          # Android status bar band at the top of the device screen
GESTURE_Y=1452       # Android gesture-handle band near the bottom
GESTURE_H=18

px() { convert "$1" -format "%[pixel:p{$2,$3}]" info:; }

for row in "${SHOTS[@]}"; do
  IFS='|' read -r name cap <<<"$row"
  ios_raw="raw/ios/$THEME/$name.png"
  if [ -f "$ios_raw" ]; then
    src="$ios_raw"
  else
    final="marketing/phone/$THEME/$name.png"
    src="work/ios_${THEME}_$name.png"
    convert "$final" -crop "${DW}x${DH}+${DX}+${DY}" +repage "$src"
    # Status bar: fill with the app bar colour from a text-free spot.
    top=$(px "$src" 333 6)
    # Gesture handle: fill with the nav bar colour just below it.
    bot=$(px "$src" 333 $((GESTURE_Y + GESTURE_H + 4)))
    convert "$src" \
      -fill "$top" -draw "rectangle 0,0 $((DW-1)),$((STATUS_H-1))" \
      -fill "$bot" -draw "rectangle 0,$GESTURE_Y $((DW-1)),$((GESTURE_Y+GESTURE_H))" \
      "$src"
  fi
  ./frame.sh ios "$src" "$OUT_DIR/$name.png" "$cap"
done

echo "=== App Store check (1320x2868, RGB, no alpha) ==="
fail=0
for f in "$OUT_DIR"/*.png; do
  info=$(identify -format '%wx%h %[channels]' "$f")
  case "$info" in "1320x2868 srgb"*) ok=OK;; *) ok=FAIL; fail=1;; esac
  echo "  $f  $info  $ok"
done
echo "fail=$fail"
exit $fail
