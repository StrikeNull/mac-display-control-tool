# DisplayBar Status Bar App

This directory contains the menu bar app and helper binaries used by DisplayBar.

## Build

```zsh
./statusbar-tool/build.sh
```

The build script compiles:

- `Sources/DisplayBar/main.swift` into `build/DisplayBar.app`
- `hdrctl.c` into `build/hdrctl`
- `profilectl.c` into `build/profilectl`
- helper copies into `build/DisplayBar.app/Contents/Resources`

## Package

From the repository root:

```zsh
./scripts/package-dmg.sh
```

This creates:

```text
dist/DisplayBar-0.1.0.dmg
```

The DMG contains `DisplayBar.app` and an `Applications` shortcut for drag-and-drop
installation.

## Run

```zsh
./statusbar-tool/run.sh
```

Or:

```zsh
open ./statusbar-tool/build/DisplayBar.app
```

## Runtime Dependencies

- Bundled `DisplayBar.app/Contents/Resources/displayplacer`
- Bundled `DisplayBar.app/Contents/Resources/displayplacer-patched` for rescue wakeups
- Homebrew `displayplacer` fallback at `/opt/homebrew/bin/displayplacer` or `/usr/local/bin/displayplacer`
- macOS AppKit, CoreGraphics, CoreDisplay/SkyLight private symbols, and ColorSync

Set a custom `displayplacer` path:

```zsh
DISPLAYPLACER=/path/to/displayplacer ./statusbar-tool/run.sh
```

Set a custom project root:

```zsh
DISPLAY_CONTROL_TOOL_HOME=/path/to/display-control-tool ./statusbar-tool/run.sh
```

## UI Behavior

The app uses an `NSPopover` instead of an `NSMenu` so controls can be clicked
without closing the panel. Display-changing actions refresh the display list and
rebuild the popover while preserving scroll position. Color profile changes do
not rebuild the whole popover on success, which avoids unnecessary UI jumping.

The main display list shows only currently active displays. Previously seen
disabled/offline displays appear in a separate recovery section.

## Direct Helper Usage

HDR:

```zsh
./statusbar-tool/build/hdrctl status 1 3
./statusbar-tool/build/hdrctl on 1
./statusbar-tool/build/hdrctl off 1
```

ColorSync profiles:

```zsh
./statusbar-tool/build/profilectl list 1 3
./statusbar-tool/build/profilectl set 1 1 /Library/ColorSync/Profiles/Displays/example.icc
./statusbar-tool/build/profilectl reset 1 1
```

## Implementation Notes

- Display layout, resolution, refresh rate, HiDPI, and enable/disable
  actions are sent through `displayplacer`.
- Color depth writes WindowServer connection-mode link depth on Apple Silicon.
- Launch at login is implemented with a per-user `LaunchAgent`.
- HDR uses private macOS APIs and verifies the state after toggling.
- Color profiles use ColorSync device APIs via `profilectl`.

## Warnings

Building currently emits two non-fatal warnings:

- `NSBox.borderType` is deprecated.
- Legacy `NSMenu` code remains after an early `return` in `rebuildMenu()`.

Both are cleanup items; they do not prevent the current popover app from running.
