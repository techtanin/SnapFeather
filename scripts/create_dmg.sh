#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SnapFeather"
APP_VERSION="${APP_VERSION:-1.0.2}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
DMG_NAME="${APP_NAME}-v${APP_VERSION}-arm64.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "==> $APP_BUNDLE not found; building first..."
    "$ROOT_DIR/scripts/build_app.sh"
fi

STAGING_DIR="$(mktemp -d)"
RW_DMG="$(mktemp -u /tmp/SnapFeather-rw-XXXXXX).dmg"
cleanup() {
    rm -rf "$STAGING_DIR" "$RW_DMG"
}
trap cleanup EXIT

echo "==> Preparing DMG staging directory..."
cp -R "$APP_BUNDLE" "$STAGING_DIR/${APP_NAME}.app"
ln -s /Applications "$STAGING_DIR/Applications"

if [[ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]]; then
    cp "$APP_BUNDLE/Contents/Resources/AppIcon.icns" "$STAGING_DIR/.VolumeIcon.icns"
fi

echo "==> Creating writable disk image..."
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDRW \
    -fs HFS+ \
    "$RW_DMG" >/dev/null

MOUNT_DIR=""
if [[ "${SKIP_FINDER_LAYOUT:-0}" != "1" ]]; then
    ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$RW_DMG")"
    MOUNT_DIR="$(echo "$ATTACH_OUT" | awk '/\/Volumes\// { idx=index($0, "/Volumes/"); print substr($0, idx); exit }')"
    if [[ -n "$MOUNT_DIR" && -d "$MOUNT_DIR" ]]; then
        if command -v SetFile >/dev/null 2>&1 && [[ -f "$MOUNT_DIR/.VolumeIcon.icns" ]]; then
            SetFile -a C "$MOUNT_DIR" || true
        fi

        VOL_BASENAME="$(basename "$MOUNT_DIR")"
        osascript <<OSA >/dev/null 2>&1 || true
tell application "Finder"
    tell disk "$VOL_BASENAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set bounds of container window to {260, 180, 780, 480}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 96
        set position of item "${APP_NAME}.app" of container window to {140, 140}
        set position of item "Applications" of container window to {380, 140}
        close
        open
        update without registering applications
        delay 1
    end tell
end tell
OSA
        sync
        hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet || true
    fi
fi

echo "==> Compressing DMG to $DMG_PATH..."
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG_PATH" >/dev/null

ls -lh "$DMG_PATH"
shasum -a 256 "$DMG_PATH"
