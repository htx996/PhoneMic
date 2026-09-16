#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
PRODUCT_NAME="PhoneMicMac"
HELPER_PRODUCT_NAME="PhoneMicUSBProxyHelper"
HELPER_BUNDLE_NAME="phonemic-usbproxy"
APP_NAME="PhoneMic"
BUNDLE_ID="app.phonemic.mac"
MIN_SYSTEM_VERSION="14.0"
BUILD_CONFIGURATION="${PHONE_MIC_BUILD_CONFIGURATION:-debug}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_FILE="PhoneMic.icns"
ICON_SOURCE="$ROOT_DIR/Resources/macOS/$ICON_FILE"

cd "$ROOT_DIR"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
pkill -x "$PRODUCT_NAME" >/dev/null 2>&1 || true

SWIFT_BUILD_FLAGS=()
if [[ "$BUILD_CONFIGURATION" == "release" ]]; then
  SWIFT_BUILD_FLAGS=(-c release)
fi

swift build "${SWIFT_BUILD_FLAGS[@]}" --product "$PRODUCT_NAME"
swift build "${SWIFT_BUILD_FLAGS[@]}" --product "$HELPER_PRODUCT_NAME"
BUILD_BIN_PATH="$(swift build "${SWIFT_BUILD_FLAGS[@]}" --show-bin-path)"
BUILD_BINARY="$BUILD_BIN_PATH/$PRODUCT_NAME"
HELPER_BINARY="$BUILD_BIN_PATH/$HELPER_PRODUCT_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS"
mkdir -p "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$HELPER_BINARY" "$APP_RESOURCES/$HELPER_BUNDLE_NAME"
chmod +x "$APP_RESOURCES/$HELPER_BUNDLE_NAME"

if [[ -f "$ICON_SOURCE" ]]; then
  cp "$ICON_SOURCE" "$APP_RESOURCES/$ICON_FILE"
fi

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleIconFile</key>
  <string>PhoneMic</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSBonjourServices</key>
  <array>
    <string>_phonemic._tcp</string>
  </array>
  <key>NSLocalNetworkUsageDescription</key>
  <string>PhoneMic connects to your iPhone on the local network to receive microphone audio.</string>
  <key>SUEnableInstallerLauncherService</key>
  <false/>
  <key>SUFeedURL</key>
  <string></string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
