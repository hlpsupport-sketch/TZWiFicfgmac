#!/bin/bash
# Signs the app with a Developer ID, notarizes it with Apple and staples the ticket.
# Needs env: KEYCHAIN, APPLE_ID, APPLE_APP_PASSWORD, APPLE_TEAM_ID
set -euo pipefail
cd "$(dirname "$0")"
APP="dist/Tzone Config.app"
IDENTITY=$(security find-identity -v -p codesigning "$KEYCHAIN" | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.+)".*/\1/')
[ -n "$IDENTITY" ] || { echo "No 'Developer ID Application' certificate found in the imported file."; exit 1; }
echo "Signing as: $IDENTITY"
SIGN=(codesign --force --timestamp --options runtime --keychain "$KEYCHAIN" --sign "$IDENTITY")

# 1) nested libraries and helper binaries first
while IFS= read -r -d '' f; do
  if file "$f" | grep -q "Mach-O"; then "${SIGN[@]}" "$f"; fi
done < <(find "$APP/Contents" -type f ! -path "*/Contents/MacOS/Tzone Config" -print0)
# 2) main executable (with entitlements), then the bundle itself
"${SIGN[@]}" --entitlements entitlements.plist "$APP/Contents/MacOS/Tzone Config"
"${SIGN[@]}" --entitlements entitlements.plist "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

# 3) notarize
ditto -c -k --keepParent "$APP" notarize.zip
OUT=$(xcrun notarytool submit notarize.zip --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" \
      --team-id "$APPLE_TEAM_ID" --wait --output-format json)
echo "$OUT"
ID=$(echo "$OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))')
STATUS=$(echo "$OUT" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("status",""))')
if [ "$STATUS" != "Accepted" ]; then
  echo "Notarization status: $STATUS"
  xcrun notarytool log "$ID" --apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID" || true
  exit 1
fi
xcrun stapler staple "$APP"
spctl -a -vvv -t exec "$APP" || true
echo "Signed and notarized."
