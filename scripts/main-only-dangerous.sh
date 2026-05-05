#!/bin/zsh
set -euo pipefail

if [[ "${1:-}" != "--yes" ]]; then
  echo "This may hide/disable the secondary display and original displayplacer may not restore it."
  echo "Run again with: $0 --yes"
  exit 2
fi

DISPLAYPLACER="${DISPLAYPLACER:-/opt/homebrew/bin/displayplacer}"

exec "$DISPLAYPLACER" \
  "id:643845E2-6FAA-4FD4-9AF4-530EA3C69D8E res:1920x1080 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0"

