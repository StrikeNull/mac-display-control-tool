#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_DIR="$("$SCRIPT_DIR/build.sh")"

open "$APP_DIR"
