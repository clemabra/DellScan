#!/bin/bash
# Baut "Dell Scan.app" (benötigt nur die Xcode Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
APP="build/Dell Scan.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/DellScan "$APP/Contents/MacOS/DellScan"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Fertig: $APP"
