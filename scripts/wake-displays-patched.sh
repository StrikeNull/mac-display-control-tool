#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PATCHED="${PATCHED_DISPLAYPLACER:-$SCRIPT_DIR/../bin/displayplacer-patched}"
DISPLAYPLACER="${DISPLAYPLACER:-/opt/homebrew/bin/displayplacer}"
RESTORE="$SCRIPT_DIR/restore-dual.sh"

if [[ ! -x "$PATCHED" ]]; then
  echo "Missing patched displayplacer binary: $PATCHED" >&2
  exit 1
fi

for i in 1 2 3 4 5 6 7 8 9 10; do
  "$PATCHED" "id:$i enabled:true quiet:true" || true
done

# Give WindowServer a moment to publish the rescued display before applying layout.
sleep 1

if "$RESTORE"; then
  exit 0
fi

# Fallback for the common post-rescue case: persistent IDs are visible again, but
# the normal restore was attempted before displayplacer could settle the layout.
"$DISPLAYPLACER" \
  "id:2 res:1920x1080 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0" \
  "id:3 res:2048x858 hz:60 color_depth:8 enabled:true scaling:on origin:(-2048,146) degree:0"
