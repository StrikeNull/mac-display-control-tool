#!/bin/zsh
set -euo pipefail

DISPLAYPLACER="${DISPLAYPLACER:-/opt/homebrew/bin/displayplacer}"

echo "== displayplacer list =="
"$DISPLAYPLACER" list

echo
echo "== system_profiler SPDisplaysDataType =="
system_profiler SPDisplaysDataType

