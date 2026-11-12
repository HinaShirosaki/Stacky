#!/bin/sh
# Builds build/Stacky.app (menu-bar only, Hardened Runtime).
# Usage: scripts/bundle.sh [identity]   (default: first Developer ID / Apple Development identity, else ad-hoc)
# A stable identity keeps the Accessibility grant across rebuilds; ad-hoc loses it every time.
set -e
cd "$(dirname "$0")/.."
pkill -x Stacky && sleep 1 || true   # a running copy would keep the old binary and swallow `open`
swift build -c release $ARCHS   # ARCHS="--arch arm64 --arch x86_64" builds a universal binary
APP=build/Stacky.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release $ARCHS --show-bin-path)/Stacky" "$APP/Contents/MacOS/"
mkdir -p "$APP/Contents/Resources" && cp Resources/AppIcon.icns "$APP/Contents/Resources/"   # regenerate: swift scripts/make-icon.swift
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.stacky.Stacky</string>
  <key>CFBundleName</key><string>Stacky</string>
  <key>CFBundleExecutable</key><string>Stacky</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
</dict></plist>
PLIST
IDENTITY="${1:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application|Apple Development/ {print $2; exit}')}"
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"
