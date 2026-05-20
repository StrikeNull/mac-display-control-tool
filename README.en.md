# DisplayBar

[中文说明](README.md)

DisplayBar is a small macOS menu bar utility for controlling external displays.
It was built around `displayplacer`, with a few local helpers for things
`displayplacer` does not expose directly, such as HDR and ColorSync profiles.

![DisplayBar menu bar control panel](docs/images/displaybar-popover.png)

## Download

The latest usable build is available from GitHub Releases:

[Download DisplayBar-0.1.0.dmg](https://github.com/StrikeNull/mac-display-control-tool/releases/download/v0.1.0/DisplayBar-0.1.0.dmg)

Open the DMG, then drag `DisplayBar.app` to `Applications`.

The app is not signed or notarized. On first launch, macOS may block it with a
Gatekeeper warning. If you trust this open-source build, open System Settings >
Privacy & Security and allow the app, or right-click the app and choose Open.

## Who It Is For

- People who frequently switch multi-display setups on macOS.
- External-display users who often change resolution, refresh rate, HiDPI, or HDR.
- Users who want quick Windows-like display modes: extend, mirror, main-only, and secondary-only.
- External-display users who need fast ColorSync profile switching.

The app is intended for personal display setups where quick switching matters:
turn a display on or off, change resolution and refresh rate, toggle HiDPI/HDR,
set the main display, choose a ColorSync profile, and open the system display
arrangement panel when manual layout is needed.

## Features

- Menu bar popover UI that stays open while changing settings.
- Always shows a `DB` menu bar entry so the app is visible when running.
- Supports launch at login.
- List currently active displays.
- Enable or disable a display through `displayplacer`.
- Recover a disabled/offline display through a patched rescue binary.
- Set display mode:
  - resolution
  - refresh rate
  - HiDPI scaling
  - connection-mode based color depth
- Read and adjust software brightness when macOS exposes it.
- Toggle HDR per display through macOS private display APIs.
- Set the main display.
- Switch screen mode:
  - extend
  - mirror
  - main display only
  - secondary display only
- Apply simple secondary-display arrangements:
  - left
  - right
  - above
  - below
- Open macOS Display Settings directly for system arrangement.
- Read and set per-display ColorSync profiles.

## Requirements

- macOS.
- Apple Silicon or Intel Mac with external display support.
- Xcode command line tools for building the Swift app and C helpers.

The downloadable app prefers the bundled `displayplacer`. Source builds look in
this order: `DISPLAYPLACER`, app Resources, `/opt/homebrew/bin/displayplacer`,
and `/usr/local/bin/displayplacer`.

## Build

Build the menu bar app and helper binaries:

```zsh
./statusbar-tool/build.sh
```

The app bundle is written to:

```text
statusbar-tool/build/DisplayBar.app
```

## Build A DMG

Create a DMG from source that can be dragged into
Applications:

```zsh
./scripts/package-dmg.sh
```

The package is written to:

```text
dist/DisplayBar-0.1.0.dmg
```

## Run

Run from the repository:

```zsh
./statusbar-tool/run.sh
```

Or open the app bundle:

```zsh
open statusbar-tool/build/DisplayBar.app
```

The status bar icon shows the number of currently active displays when more
than one display is enabled.

## Environment

Optional overrides:

```zsh
DISPLAYPLACER=/path/to/displayplacer
DISPLAY_CONTROL_TOOL_HOME=/path/to/display-control-tool
```

## Helpers

HDR helper:

```zsh
./statusbar-tool/build/hdrctl status 1 3
./statusbar-tool/build/hdrctl on 1
./statusbar-tool/build/hdrctl off 1
```

ColorSync profile helper:

```zsh
./statusbar-tool/build/profilectl list 1 3
./statusbar-tool/build/profilectl set 1 1 /Library/ColorSync/Profiles/Displays/example.icc
./statusbar-tool/build/profilectl reset 1 1
```

Patched display wake helper:

```zsh
./scripts/wake-displays-patched.sh
```

## Display Disable And Recovery

Disabling a display with `displayplacer` can make that display disappear from
`displayplacer list`. When that happens, normal `displayplacer` may refuse to
operate on the missing display id.

DisplayBar keeps a lightweight record of previously seen displays and shows
disabled/offline displays in a separate recovery section. For displays that
vanish after being disabled, it can use `bin/displayplacer-patched` as a rescue
path.

Treat display disabling as an advanced action. The safest way to temporarily
"turn off" a display is often a black overlay, not a real display disable.

## HDR Notes

`displayplacer` does not expose HDR controls. DisplayBar uses private macOS
display APIs:

- `CoreDisplay_Display_SupportsHDRMode`
- `CoreDisplay_Display_IsHDRModeEnabled`
- `CoreDisplay_Display_SetHDRModeEnabled`
- `SLSDisplaySupportsHDRMode`
- `SLSDisplayIsHDRModeEnabled`
- `SLSDisplaySetHDRModeEnabled`

These APIs can change between macOS releases. If macOS reports the requested
HDR state after toggling, DisplayBar treats the operation as successful.

## Color Profiles

Color profiles use public ColorSync APIs through `profilectl`.

DisplayBar reads the profiles associated with each display from ColorSync and
uses those display-specific profiles for the popover. It does not present every
ICC file installed on the system as if it belonged to every display.

Some displays expose generic ColorSync profile names such as `HDMI HD`; when
that happens, DisplayBar falls back to the ICC profile description or filename
for a clearer label.

## 10-bit Color Depth

DisplayBar shows both graphics color depth and link color depth. Graphics depth
comes from the current macOS graphics mode, while link depth comes from
WindowServer `LinkDescription.BitDepth`.

On Apple Silicon, `displayplacer list` may expose only `color_depth:8` even when
the underlying link can run at 10-bit. DisplayBar's color-depth selector writes
the connection-mode link depth instead of only sending `displayplacer
color_depth:10`.

10-bit should be considered active only if macOS reads back a `10-bit` link
depth. If it still reads back `8-bit`, the current macOS, cable, refresh rate,
HDR state, or display combination did not accept the 10-bit request.

## Repository Layout

```text
.
├── bin/
│   └── displayplacer-patched
├── patches/
│   ├── README.md
│   └── changes.diff.txt
├── scripts/
│   ├── check-displays.sh
│   ├── main-only-dangerous.sh
│   ├── package-dmg.sh
│   ├── restore-dual.sh
│   └── wake-displays-patched.sh
└── statusbar-tool/
    ├── Sources/DisplayBar/main.swift
    ├── build.sh
    ├── hdrctl.c
    ├── profilectl.c
    └── run.sh
```

## Known Limitations

- The app is tailored for local macOS display experiments, not a polished
  signed distribution.
- HDR uses private APIs and may break on future macOS versions.
- Display enable/disable behavior depends heavily on macOS, display firmware,
  cable, dock, and `displayplacer`.
- 10-bit mode cannot be guaranteed unless macOS reads it back as active.
- The patched rescue binary is a workaround for disappearing displays, not a
  general replacement for upstream `displayplacer`.
