#!/bin/bash
# Builds a universal (Intel + Apple Silicon) "Tzone Config.app" next to this script.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/TzoneConfig"
APP="Tzone Config.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/TzoneConfig"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Tzone Config</string>
<key>CFBundleDisplayName</key><string>Tzone Config</string>
<key>CFBundleIdentifier</key><string>au.com.hlpcontrols.tzoneconfig</string>
<key>CFBundleExecutable</key><string>TzoneConfig</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
codesign --force --deep --sign - "$APP"
ditto -c -k --keepParent "$APP" TzoneConfig-Mac.zip
echo "Built: $APP and TzoneConfig-Mac.zip"
