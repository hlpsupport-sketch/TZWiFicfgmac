#!/bin/bash
# Builds a universal "Tzone Config.app" with plain clang (no Swift, no SwiftPM).
set -euo pipefail
cd "$(dirname "$0")"
APP="Tzone Config.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS"
clang -arch x86_64 -arch arm64 -mmacosx-version-min=10.15 -O2 -fobjc-arc \
  -Wl,-no_fixup_chains \
  -ISources/CSCSI/include \
  -o "$APP/Contents/MacOS/TzoneConfig" Sources/main.m Sources/CSCSI/cscsi.c \
  -framework Cocoa -framework IOKit -framework CoreFoundation
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Tzone Config</string>
<key>CFBundleDisplayName</key><string>Tzone Config</string>
<key>CFBundleIdentifier</key><string>au.com.hlpcontrols.tzoneconfig</string>
<key>CFBundleExecutable</key><string>TzoneConfig</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.1</string>
<key>CFBundleVersion</key><string>2</string>
<key>LSMinimumSystemVersion</key><string>10.15</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
file "$APP/Contents/MacOS/TzoneConfig"
codesign --force --deep --sign - "$APP"
codesign -vvv "$APP"
ditto -c -k --keepParent "$APP" TzoneConfig-Mac.zip
echo "Built $APP"
