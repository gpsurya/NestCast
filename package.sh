#!/bin/bash
# package.sh — builds a verified drag-to-Applications DMG for NestCast
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NestCast"
VERSION="${VERSION:-1.0.4}"
ARCH=$(uname -m)
BUILD_DIR="${NESTCAST_BUILD_DIR:-$PWD/build/release-$VERSION-$ARCH}"
DIST_DIR="${NESTCAST_DIST_DIR:-$PWD/dist}"
DMG_OUT="$DIST_DIR/$APP_NAME-$VERSION-$ARCH.dmg"

if [[ -e "$DMG_OUT" ]]; then
  echo "Refusing to overwrite existing DMG: $DMG_OUT" >&2
  exit 1
fi

STAGING=$(mktemp -d "${TMPDIR:-/tmp}/NestCast-dmg.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT

VERSION="$VERSION" NESTCAST_BUILD_DIR="$BUILD_DIR" bash build.sh
APP="$BUILD_DIR/$APP_NAME.app"

codesign --verify --deep --strict "$APP"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"

cat > "$STAGING/READ ME.txt" <<'INSTALL'
NestCast — macOS Menu Bar audio casting to Google Nest Mini over Wi-Fi

Drag NestCast.app into Applications, then launch it.
The app stays in your Menu Bar (no Dock icon).
Click the Cast icon to see all discovered Google Nest Minis on your Wi-Fi network.

Features:
• Auto-discovery of Google Nest & Chromecast speakers via Bonjour / mDNS.
• Live Volume Control & Play/Pause via Cast V2 protocol.
• System Audio Bridge: 1-click toggle to expose all Nest speakers as native AirPlay sound outputs.
• Zero Bluetooth latency or range limits — streams purely over Wi-Fi.

Source and releases: https://github.com/gpsurya/NestCast
INSTALL

mkdir -p "$DIST_DIR"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -format UDZO -imagekey zlib-level=9 "$DMG_OUT"
hdiutil verify "$DMG_OUT"
(cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_OUT")" > "$(basename "$DMG_OUT").sha256")

printf '\n✓ Verified DMG created: %s\n' "$DMG_OUT"
