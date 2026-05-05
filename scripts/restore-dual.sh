#!/bin/zsh
set -euo pipefail

DISPLAYPLACER="${DISPLAYPLACER:-/opt/homebrew/bin/displayplacer}"

exec "$DISPLAYPLACER" \
  "id:643845E2-6FAA-4FD4-9AF4-530EA3C69D8E res:1920x1080 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0" \
  "id:DC01248D-9DAA-4C45-8EA2-E70EE246333A res:2048x858 hz:60 color_depth:8 enabled:true scaling:on origin:(-2048,146) degree:0"

