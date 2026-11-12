# SnapFeather

Native Apple Silicon (`arm64`) screenshot, annotation, and Google Drive upload utility for macOS, built with **Swift 6**, **AppKit**, **ScreenCaptureKit**, and **libwebp**.

## Features
- **Menu Bar App (`LSUIElement`)**: Lightweight resident app with zero Dock clutter.
- **Global Hotkey**: Instant region capture via `⌘⇧2` (customizable in Preferences).
- **Retina ScreenCaptureKit**: Fast multi-monitor frozen overlay at native backing scale.
- **Interactive Selection & Editing**:
  - Drag to select, 8 resize handles, drag-to-move region, live point & pixel dimensions badge, and crosshair guides.
  - Select (`1`) existing annotations to move, nudge (`Arrow` / `Shift+Arrow`), or delete (`Delete`).
- **Lightshot-style Floating Toolbars**:
  - **Tools (`1`–`8`)**: Select/Move, Pen, Line, Arrow, Rectangle, Ellipse, Marker (Highlighter), Inline Text.
  - **Color & Size Popover**: Active color checkmark, continuous **Brush Size** (`1–24 pt`) and **Text Font Size** (`12–72 pt`) sliders, preset pills, live cursor brush-size circle, and `⌥ + Scroll` (or `[` / `]`) live resizing.
  - **Actions**: Copy (`⌘C` / `Enter`), Quick Save, Save As (`⌘S` with **PNG**, **JPG**, and **WebP** format selector), Upload to Google Drive, Print (`⌘P`), macOS Share Sheet, Cancel (`Esc`).
- **Google Drive Integration**:
  - PKCE OAuth 2.0 Desktop flow with macOS Keychain storage for tokens and client secret.
  - Configurable Drive folder, auto-upload after copying or saving, optional shareable links, and upload toast notifications.

## Requirements
- macOS 14+ on Apple Silicon (`arm64`)
- Xcode Command Line Tools (Swift 6+)
- Homebrew `webp` (`brew install webp`) for static `libwebp` linking

## Install (Prebuilt `.dmg`)

1. Download **`SnapFeather-v<version>-arm64.dmg`** from [GitHub Releases](https://github.com/techtanin/SnapFeather/releases).
2. Open the `.dmg` and drag **`SnapFeather.app`** onto **`Applications`**.
3. First launch (ad-hoc signed): if macOS Gatekeeper blocks opening, go to **System Settings → Privacy & Security → Open Anyway**, or run:
   ```bash
   xattr -cr /Applications/SnapFeather.app && open /Applications/SnapFeather.app
   ```

## Build, Test & Package From Source

```bash
# Run unit tests
swift test -Xswiftc -load-plugin-library -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib

# Build native arm64 .app bundle at dist/SnapFeather.app
chmod +x scripts/build_app.sh scripts/create_dmg.sh
./scripts/build_app.sh

# Package drag-and-drop macOS DMG installer at dist/SnapFeather-v<version>-arm64.dmg
./scripts/create_dmg.sh

# Launch the app
open dist/SnapFeather.app
```

> **Note**: On first capture, grant **Screen Recording** permission in **System Settings → Privacy & Security → Screen & System Audio Recording**.
