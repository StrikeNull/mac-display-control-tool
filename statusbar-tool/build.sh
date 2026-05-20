#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP_DIR="$SCRIPT_DIR/build/DisplayBar.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
MODULE_CACHE="$SCRIPT_DIR/build/ModuleCache"

mkdir -p "$MACOS_DIR"
mkdir -p "$RESOURCES_DIR"
mkdir -p "$MODULE_CACHE"
cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE"

swiftc \
  -swift-version 5 \
  -target arm64-apple-macos13.0 \
  "$SCRIPT_DIR/Sources/DisplayBar/main.swift" \
  -F /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/PrivateFrameworks \
  -framework AppKit \
  -framework ColorSync \
  -framework CoreGraphics \
  -framework CoreDisplay \
  -framework DisplayServices \
  -framework SkyLight \
  -o "$MACOS_DIR/DisplayBar"

clang \
  "$SCRIPT_DIR/hdrctl.c" \
  -F /Library/Developer/CommandLineTools/SDKs/MacOSX.sdk/System/Library/PrivateFrameworks \
  -framework CoreGraphics \
  -framework CoreDisplay \
  -framework SkyLight \
  -o "$SCRIPT_DIR/build/hdrctl"

clang \
  "$SCRIPT_DIR/profilectl.c" \
  -framework ApplicationServices \
  -framework ColorSync \
  -framework CoreGraphics \
  -o "$SCRIPT_DIR/build/profilectl"

cp "$SCRIPT_DIR/build/profilectl" "$RESOURCES_DIR/profilectl"
cp "$SCRIPT_DIR/build/hdrctl" "$RESOURCES_DIR/hdrctl"
if [[ -x "$SCRIPT_DIR/../bin/displayplacer-patched" ]]; then
  cp "$SCRIPT_DIR/../bin/displayplacer-patched" "$RESOURCES_DIR/displayplacer-patched"
  cp "$SCRIPT_DIR/../bin/displayplacer-patched" "$RESOURCES_DIR/displayplacer"
  chmod +x "$RESOURCES_DIR/displayplacer-patched" "$RESOURCES_DIR/displayplacer"
fi

xattr -cr "$APP_DIR"
codesign --force --deep --sign - "$APP_DIR"

echo "$APP_DIR"
