#!/usr/bin/env bash
# Builds Lantern.app and zips it for a GitHub release. Ad-hoc signed, not notarized.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-1.0}"
APP=build/Lantern.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" dist
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources" && cp Resources/Lantern.icns "$APP/Contents/Resources/"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
swiftc -O -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/Lantern" \
  -framework SwiftUI -framework CoreBluetooth -framework ScreenCaptureKit
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
rm -f "dist/Lantern-$VERSION.zip"
ditto -c -k --keepParent "$APP" "dist/Lantern-$VERSION.zip"
shasum -a 256 "dist/Lantern-$VERSION.zip" | tee "dist/Lantern-$VERSION.zip.sha256"
