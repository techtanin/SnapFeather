#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_VERSION="${APP_VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"

if [[ -z "$APP_SIGN_IDENTITY" || -z "$INSTALLER_SIGN_IDENTITY" || -z "$PROVISIONING_PROFILE" ]]; then
    cat <<USAGE
Usage:
  APP_SIGN_IDENTITY="Apple Distribution: Your Name (TEAM_ID)" \\
  INSTALLER_SIGN_IDENTITY="3rd Party Mac Developer Installer: Your Name (TEAM_ID)" \\
  PROVISIONING_PROFILE="/path/to/SnapFeather_MAS.provisionprofile" \\
  APP_VERSION="1.0.0" \\
  BUILD_NUMBER="1" \\
  ./scripts/package_mas.sh

Notes:
  - Both certificates must exist in your Keychain (Xcode -> Settings -> Accounts -> Manage Certificates).
  - PROVISIONING_PROFILE must be a Mac App Store Distribution profile for bundle ID: com.taninahmed.snapfeather
  - Output package will be written to: dist/SnapFeather-<APP_VERSION>+<BUILD_NUMBER>-MAS.pkg
USAGE
    exit 1
fi

export APP_VERSION
export BUILD_NUMBER
export SIGN_IDENTITY="$APP_SIGN_IDENTITY"
export PROVISIONING_PROFILE
export USE_SANDBOX=1

"$ROOT_DIR/scripts/build_app.sh"

PKG_PATH="$ROOT_DIR/dist/SnapFeather-${APP_VERSION}+${BUILD_NUMBER}-MAS.pkg"
rm -f "$PKG_PATH"

echo "==> Packaging Mac App Store installer (.pkg)..."
productbuild \
    --component "$ROOT_DIR/dist/SnapFeather.app" /Applications \
    --sign "$INSTALLER_SIGN_IDENTITY" \
    "$PKG_PATH"

echo "==> Verifying .pkg signature..."
pkgutil --check-signature "$PKG_PATH"

echo "==> Ready for Transporter / App Store Connect upload:"
echo "    $PKG_PATH"
