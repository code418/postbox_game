#!/usr/bin/env bash
# Composite a raw device screenshot onto a Play Store-compliant branded marketing frame.
#
# Usage:
#   frame.sh phone <raw.png> <out.png> "<caption>"      -> 1080x1920 (9:16, compliant)
#   frame.sh wear  <raw.png> <out.png> "<caption>"      -> 1080x1080 (1:1, round-masked dial)
#
# Brand: postal red #C8102E, royal navy #0A1931, gold #FFB400.
set -euo pipefail

KIND="$1"; RAW="$2"; OUT="$3"; CAPTION="${4:-}"
DIR="$(cd "$(dirname "$0")" && pwd)"
FONT_SANS="$DIR/fonts/PlusJakartaSans.ttf"
FONT_SERIF="$DIR/fonts/PlayfairDisplay.ttf"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

RED="#C8102E"; NAVY="#0A1931"; GOLD="#FFB400"

if [ "$KIND" = "phone" ]; then
  CW=1080; CH=1920
  DEV_H=1480                      # device screenshot target height
  # 1) rounded corners on the screenshot
  read -r W H < <(identify -format '%w %h\n' "$RAW")
  NW=$(( DEV_H * W / H ))
  convert "$RAW" -resize "${NW}x${DEV_H}" "$TMP/dev.png"
  convert -size "${NW}x${DEV_H}" xc:black -fill white -draw "roundrectangle 0,0,$((NW-1)),$((DEV_H-1)),40,40" "$TMP/mask.png"
  convert "$TMP/dev.png" "$TMP/mask.png" -alpha off -compose CopyOpacity -composite "$TMP/devr.png"
  # 2) soft drop shadow
  convert "$TMP/devr.png" \( +clone -background black -shadow 60x20+0+16 \) \
    +swap -background none -layers merge +repage "$TMP/devsh.png"
  # 3) brand gradient canvas (angled red -> navy)
  convert -size "${CH}x${CW}" gradient:"$RED"-"$NAVY" -rotate 90 "$TMP/bg.png"
  convert "$TMP/bg.png" -resize "${CW}x${CH}!" "$TMP/bg.png"
  # 4) caption block (two lines wrap), gold rule under it
  if [ -n "$CAPTION" ]; then
    convert -background none -fill white -font "$FONT_SANS" -weight 700 \
      -pointsize 62 -size 940x -gravity center caption:"$CAPTION" "$TMP/cap.png"
    convert -size 180x6 xc:"$GOLD" "$TMP/rule.png"
  fi
  # 5) assemble: device sits lower, caption up top
  convert "$TMP/bg.png" \
    "$TMP/devsh.png" -gravity south -geometry +0-40 -composite \
    "$TMP/out.png"
  if [ -n "$CAPTION" ]; then
    convert "$TMP/out.png" "$TMP/cap.png" -gravity north -geometry +0+96 -composite "$TMP/out.png"
    convert "$TMP/out.png" "$TMP/rule.png" -gravity north -geometry +0+250 -composite "$TMP/out.png"
  fi
  convert "$TMP/out.png" -background "$NAVY" -flatten -depth 8 "$OUT"

elif [ "$KIND" = "wear" ]; then
  CW=1080; CH=1080
  DIAL=720
  # round-mask the watch capture into a circle
  read -r W H < <(identify -format '%w %h\n' "$RAW")
  S=$(( W < H ? W : H ))
  convert "$RAW" -gravity center -extent "${S}x${S}" -resize "${DIAL}x${DIAL}" "$TMP/dial.png"
  convert -size "${DIAL}x${DIAL}" xc:none -fill white -draw "circle $((DIAL/2)),$((DIAL/2)) $((DIAL/2)),2" "$TMP/cmask.png"
  convert "$TMP/dial.png" "$TMP/cmask.png" -alpha off -compose CopyOpacity -composite "$TMP/dialr.png"
  convert "$TMP/dialr.png" \( +clone -background black -shadow 70x24+0+12 \) \
    +swap -background none -layers merge +repage "$TMP/dialsh.png"
  convert -size "${CW}x${CH}" radial-gradient:"$RED"-"$NAVY" "$TMP/bg.png"
  convert "$TMP/bg.png" "$TMP/dialsh.png" -gravity center -geometry +0-30 -composite "$TMP/out.png"
  if [ -n "$CAPTION" ]; then
    convert -background none -fill white -font "$FONT_SANS" -weight 700 \
      -pointsize 52 -size 900x -gravity center caption:"$CAPTION" "$TMP/cap.png"
    convert "$TMP/out.png" "$TMP/cap.png" -gravity south -geometry +0+60 -composite "$TMP/out.png"
  fi
  convert "$TMP/out.png" -background "$NAVY" -flatten -depth 8 "$OUT"
else
  echo "unknown kind: $KIND" >&2; exit 2
fi

identify -format 'wrote %f  %wx%h  %[channels]\n' "$OUT"
