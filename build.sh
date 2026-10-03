#!/usr/bin/env bash
# Builds Lantern.app (menu bar app) and installs it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
APP=build/Lantern.app
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/"
mkdir -p "$APP/Contents/Resources" && cp Resources/Lantern.icns "$APP/Contents/Resources/"
swiftc -O -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/Lantern" \
  -framework SwiftUI -framework CoreBluetooth -framework ScreenCaptureKit
codesign --force --sign - "$APP"
mkdir -p ~/Applications
rm -rf ~/Applications/Lantern.app && cp -R "$APP" ~/Applications/
echo "installed ~/Applications/Lantern.app"
