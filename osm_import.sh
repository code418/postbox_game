#!/usr/bin/env bash
#
# osm_import.sh — fetch the UK postbox dataset from Overpass and run the
# Firestore importer. Pass-through: any unrecognised arg is forwarded to
# functions/import_postboxes.js (e.g. --dry-run, --prune, --no-manifest,
# --limit N, --overwrite-corrections, --project ...).
#
# Script-level flag:
#   --skip-download   Reuse the existing ./postboxes.json instead of fetching.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

OUT="postboxes.json"
TMP="${OUT}.tmp"
ENDPOINT="https://overpass-api.de/api/interpreter"
USER_AGENT="postbox-game-import/1.0 (+richard@agilepixel.io)"

skip_download=0
forward_args=()
for arg in "$@"; do
  case "$arg" in
    --skip-download) skip_download=1 ;;
    *)               forward_args+=("$arg") ;;
  esac
done

if [ "$skip_download" -eq 0 ]; then
  echo "Fetching UK postboxes from Overpass…"
  start=$(date +%s)

  # Heredoc query — readable, easy to tweak. [timeout:300] is the server-side
  # budget for the query itself; curl's --max-time is the client-side cap.
  curl \
    --fail-with-body \
    --retry 5 --retry-delay 10 --retry-all-errors \
    --connect-timeout 30 --max-time 600 \
    -sS \
    -A "$USER_AGENT" \
    --data-urlencode 'data@-' \
    -o "$TMP" \
    "$ENDPOINT" <<'OVERPASS'
[out:json][timeout:300];
area["name"="United Kingdom"]->.uk;
node[amenity=post_box](area.uk);
out;
OVERPASS

  # Sanity-check the response before clobbering the last good file. node is
  # already a project dependency — no extra tooling. A throttled/HTML error
  # response or a near-empty payload fails fast and leaves the tmp file in
  # place for inspection.
  node -e '
    const fs = require("fs");
    const data = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
    if (!Array.isArray(data.elements) || data.elements.length < 1000) {
      console.error("Unexpected Overpass response: elements=" +
        (data.elements?.length ?? "missing"));
      process.exit(1);
    }
  ' "$TMP"

  mv "$TMP" "$OUT"
  size=$(wc -c < "$OUT" | tr -d ' ')
  elapsed=$(( $(date +%s) - start ))
  echo "Downloaded $OUT ($(numfmt --to=iec "$size" 2>/dev/null || echo "${size}B")) in ${elapsed}s."
else
  if [ ! -f "$OUT" ]; then
    echo "Error: --skip-download set but $SCRIPT_DIR/$OUT does not exist." >&2
    exit 1
  fi
  echo "Reusing existing $OUT (--skip-download)."
fi

echo "Running importer…"
# import_postboxes.js wants to run from functions/ so node_modules resolve.
cd functions
exec node import_postboxes.js "../$OUT" --project the-postbox-game "${forward_args[@]}"
