#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="PhoneMic"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-dev.dmg"
VERSION_FILE="$DIST_DIR/version.json"
CHECKSUM_FILE="$DIST_DIR/checksums.txt"

cd "$ROOT_DIR"

PHONE_MIC_BUILD_CONFIGURATION=release "$ROOT_DIR/script/build_and_run.sh" --verify

rm -f "$DMG_PATH" "$VERSION_FILE" "$CHECKSUM_FILE"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$APP_BUNDLE" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

APP_SHA="$(/usr/bin/shasum -a 256 "$APP_BUNDLE/Contents/MacOS/$APP_NAME" | awk '{print $1}')"
HELPER_SHA="$(/usr/bin/shasum -a 256 "$APP_BUNDLE/Contents/Resources/phonemic-usbproxy" | awk '{print $1}')"
DMG_SHA="$(/usr/bin/shasum -a 256 "$DMG_PATH" | awk '{print $1}')"

cat >"$VERSION_FILE" <<JSON
{
  "name": "PhoneMic",
  "channel": "development",
  "sparkle": "placeholder",
  "notarized": false,
  "halDriverIncluded": false,
  "usbHelperIncluded": true,
  "createdAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "artifacts": {
    "app": "PhoneMic.app",
    "dmg": "PhoneMic-dev.dmg"
  }
}
JSON

{
  echo "$APP_SHA  PhoneMic.app/Contents/MacOS/PhoneMic"
  echo "$HELPER_SHA  PhoneMic.app/Contents/Resources/phonemic-usbproxy"
  echo "$DMG_SHA  PhoneMic-dev.dmg"
} >"$CHECKSUM_FILE"

echo "Created $DMG_PATH"
echo "Wrote $VERSION_FILE"
echo "Wrote $CHECKSUM_FILE"
