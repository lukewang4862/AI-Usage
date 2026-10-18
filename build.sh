#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="build/AI Usage.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -target arm64-apple-macos14.0 -O \
  -framework AppKit -framework WebKit -framework Security -framework LocalAuthentication \
  Sources/GrokBridge.swift Sources/MuseActionDiscovery.swift Sources/MuseBridge.swift Sources/main.swift \
  -o "$APP/Contents/MacOS/CodexUsage"
cp Resources/Info.plist "$APP/Contents/Info.plist"
mkdir -p build/AppIcon.iconset
swift Resources/icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
# Finder may attach metadata to the generated bundle on this Mac.
if xattr -p com.apple.FinderInfo "$APP" >/dev/null 2>&1; then
  xattr -d com.apple.FinderInfo "$APP"
fi
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
printf 'Built: %s\n' "$PWD/$APP"
