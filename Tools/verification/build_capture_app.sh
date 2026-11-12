#!/bin/zsh
# Builds "BitPolish Capture Test.app" from capture.swift, as an app so macOS's
# one-time "record audio" permission prompt names this test tool.
set -euo pipefail
cd "$(dirname "$0")"
APP="BitPolish Capture Test.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macosx14.4 -o "$APP/Contents/MacOS/CaptureTest" capture.swift
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.blockstarsoftware.BitPolishCaptureTest</string>
<key>CFBundleName</key><string>BitPolish Capture Test</string>
<key>CFBundleExecutable</key><string>CaptureTest</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>14.4</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Captures one app's audio output once, to check it reaches the DAC bit for bit.</string>
</dict></plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $PWD/$APP"
