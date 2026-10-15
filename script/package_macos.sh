#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="PhoneMic"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
DMG_PATH="$DIST_DIR/$APP_NAME-dev.dmg"
VERSION_FILE="$DIST_DIR/version.json"
CHECKSUM_FILE="$DIST_DIR/checksums.txt"
MACOS_CODESIGN_IDENTITY="${MACOS_CODESIGN_IDENTITY:--}"
DMG_WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/PhoneMic-dmg.XXXXXX")"
DMG_STAGING_DIR="$DMG_WORK_DIR/staging"
DMG_MOUNT_DIR="$DMG_WORK_DIR/mount"
DMG_RW_PATH="$DMG_WORK_DIR/$APP_NAME-rw.dmg"
DMG_MOUNTED=false

cleanup() {
  if [[ "$DMG_MOUNTED" == true ]]; then
    /usr/bin/hdiutil detach "$DMG_MOUNT_DIR" -quiet || true
  fi
  case "$DMG_WORK_DIR" in
    "${TMPDIR:-/tmp}"/PhoneMic-dmg.*) /bin/rm -rf "$DMG_WORK_DIR" ;;
  esac
}
trap cleanup EXIT

cd "$ROOT_DIR"

PHONE_MIC_BUILD_CONFIGURATION=release "$ROOT_DIR/script/build_and_run.sh" --verify

# The Swift linker may leave an ad-hoc signature on the executable, but that
# does not seal the application bundle or its bundled helper. Sign both code
# objects explicitly so Gatekeeper does not interpret the downloaded app as
# a malformed/corrupted bundle. Pass MACOS_CODESIGN_IDENTITY for a real
# Apple Development or Developer ID Application certificate; '-' keeps the
# local development fallback ad-hoc signed.
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
/usr/bin/codesign --force --timestamp=none \
  --sign "$MACOS_CODESIGN_IDENTITY" \
  "$APP_BUNDLE/Contents/Resources/phonemic-usbproxy"
/usr/bin/codesign --force --timestamp=none --options runtime \
  --sign "$MACOS_CODESIGN_IDENTITY" \
  "$APP_BUNDLE"

/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

rm -f "$DMG_PATH" "$VERSION_FILE" "$CHECKSUM_FILE"

/bin/mkdir -p "$DMG_STAGING_DIR/.background" "$DMG_MOUNT_DIR"
/usr/bin/ditto "$APP_BUNDLE" "$DMG_STAGING_DIR/$APP_NAME.app"
/bin/ln -s /Applications "$DMG_STAGING_DIR/Applications"
/usr/bin/xcrun swift "$ROOT_DIR/script/generate_dmg_background.swift" \
  "$DMG_STAGING_DIR/.background/PhoneMicDMGBackground.png"

/usr/bin/hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGING_DIR" \
  -size 64m \
  -fs HFS+ \
  -ov \
  -format UDRW \
  "$DMG_RW_PATH" >/dev/null

/usr/bin/hdiutil attach \
  "$DMG_RW_PATH" \
  -readwrite \
  -noverify \
  -nobrowse \
  -mountpoint "$DMG_MOUNT_DIR" >/dev/null
DMG_MOUNTED=true

/usr/bin/osascript - "$DMG_MOUNT_DIR" <<'APPLESCRIPT'
on run argv
    set mountPath to item 1 of argv
    tell application "Finder"
        set dmgFolder to folder (POSIX file mountPath as alias)
        open dmgFolder
        tell container window of dmgFolder
            set current view to icon view
            set toolbar visible to false
            set statusbar visible to false
            set pathbar visible to false
            set sidebar width to 0
            set bounds to {160, 120, 880, 560}
        end tell
        tell icon view options of container window of dmgFolder
            set arrangement to not arranged
            set icon size to 112
            set text size to 14
            set background picture to file ".background:PhoneMicDMGBackground.png" of dmgFolder
        end tell
        set position of item "PhoneMic.app" of dmgFolder to {180, 230}
        set position of item "Applications" of dmgFolder to {540, 230}
        update dmgFolder without registering applications
        delay 2
        close container window of dmgFolder
    end tell
end run
APPLESCRIPT

/bin/sync
/usr/bin/hdiutil detach "$DMG_MOUNT_DIR" -quiet
DMG_MOUNTED=false

/usr/bin/hdiutil convert \
  "$DMG_RW_PATH" \
  -ov \
  -format UDZO \
  -imagekey zlib-level=9 \
  -o "$DMG_PATH" >/dev/null

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
