#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
APP_NAME="DisplayBar"
VERSION="${1:-0.1.0}"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/statusbar-tool/build"
APP_PATH="$BUILD_DIR/$APP_NAME.app"
STAGE_DIR="$DIST_DIR/dmg-stage"
DMG_PATH="$DIST_DIR/$APP_NAME-$VERSION.dmg"
LATEST_DMG_PATH="$DIST_DIR/$APP_NAME.dmg"

"$ROOT_DIR/statusbar-tool/build.sh" >/dev/null

rm -rf "$STAGE_DIR"
mkdir -p "$STAGE_DIR"
mkdir -p "$DIST_DIR"

cp -R "$APP_PATH" "$STAGE_DIR/$APP_NAME.app"
ln -s /Applications "$STAGE_DIR/Applications"

rm -f "$DMG_PATH" "$LATEST_DMG_PATH"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

cp "$DMG_PATH" "$LATEST_DMG_PATH"
rm -rf "$STAGE_DIR"

echo "$DMG_PATH"
echo "$LATEST_DMG_PATH"
