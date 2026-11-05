#!/bin/bash
# build.sh — builds NestCast.app from the Swift Package
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="NestCast"
BUNDLE_ID="com.gpsurya.NestCast"
VERSION="${VERSION:-1.0.4}"
ARCH=$(uname -m)
BUILD_DIR="${NESTCAST_BUILD_DIR:-$(pwd)/build}"
APP="$BUILD_DIR/$APP_NAME.app"
SPM_RELEASE_DIR=".build/${ARCH}-apple-macosx/release"

echo "→ Building $APP_NAME $VERSION ($ARCH)..."

swift build -c release
SPM_RELEASE_DIR="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
mkdir -p "$APP/Contents/Resources"

# Copy binary
cp "$SPM_RELEASE_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"

# Copy helper resources
if [ -d Resources ]; then
    cp Resources/* "$APP/Contents/Resources/" 2>/dev/null || true
    if [ -f "$APP/Contents/Resources/aircast" ]; then
        chmod +x "$APP/Contents/Resources/aircast"
    fi
fi

# Codesign with ad-hoc signature
codesign --sign - --force --deep "$APP"
codesign --verify --deep --strict "$APP"

echo ""
echo "✓ Successfully built: $APP"
echo "✓ Version: $VERSION"
echo ""
echo "  Launch: open \"$APP\""
echo ""
