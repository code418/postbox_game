#!/usr/bin/env bash
# Build ordered, Play-compliant marketing finals from the captured raws.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p marketing/phone/light marketing/phone/dark marketing/wear

# Phone marquee: "NN|source_basename|caption"  (08 uses the PII-redacted source)
PHONE=(
  "1|04_claim_initial|Stand close. Tap. Claim."
  "2|02_nearby_results|Postboxes worth points, nearby"
  "3|03_fuzzy_compass|Hints, not directions"
  "4|06_claim_quiz|Name the royal cypher"
  "5|07_claimed|Rarer boxes, bigger scores"
  "6|08_leaderboard|Climb the leaderboards"
  "7|12_route_live|Where now, postie?"
  "8|09_history_map|Every pin, a place you've been"
)

for theme in light dark; do
  for row in "${PHONE[@]}"; do
    IFS='|' read -r n base cap <<<"$row"
    if [ "$base" = "08_leaderboard" ]; then
      src="raw/phone/${theme}_redacted/$base.png"
    else
      src="raw/phone/$theme/$base.png"
    fi
    out="marketing/phone/$theme/$(printf '%02d' "$n")_${base#??_}.png"
    ./frame.sh phone "$src" "$out" "$cap"
  done
done

# Wear (dark only — watch UI has no light theme): "NN|source|caption"
WEAR=(
  "1|01_scan|Claim from your wrist"
  "2|02_claim|Scan & claim on the go"
  "3|03_stats|Your stats, at a glance"
)
for row in "${WEAR[@]}"; do
  IFS='|' read -r n base cap <<<"$row"
  src="raw/wear/dark_redacted/$base.png"
  out="marketing/wear/$(printf '%02d' "$n")_${base#??_}.png"
  ./frame.sh wear "$src" "$out" "$cap"
done

echo "=== compliance check ==="
fail=0
for f in marketing/phone/*/*.png marketing/wear/*.png; do
  read -r w h <<<"$(identify -format '%w %h' "$f")"
  ratio=$(awk -v a="$w" -v b="$h" 'BEGIN{m=(a>b?a:b); n=(a<b?a:b); printf "%.3f", m/n}')
  ok="OK"; awk -v r="$ratio" 'BEGIN{exit !(r>2.0)}' && { ok="FAIL>2x"; fail=1; }
  echo "  $f  ${w}x${h}  ratio=$ratio  $ok"
done
echo "fail=$fail"
