#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
OUTPUT="$ROOT_DIR/outputs/PhoneMicIOS-resignable-release.ipa"
STAGING_DIR="$(mktemp -d "$ROOT_DIR/work/ipa-release.XXXXXX")"
export DEVELOPER_DIR

cd "$ROOT_DIR"

xcodebuild \
  -project PhoneMic.xcodeproj \
  -scheme PhoneMicIOS \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$ROOT_DIR/build/XcodeDerivedDataRelease" \
  CODE_SIGNING_ALLOWED=NO \
  ENABLE_PREVIEWS=NO \
  build

APP_PATH="$ROOT_DIR/build/XcodeDerivedDataRelease/Build/Products/Release-iphoneos/PhoneMicIOS.app"
PAYLOAD_DIR="$STAGING_DIR/Payload"
mkdir -p "$PAYLOAD_DIR"
/usr/bin/ditto --norsrc "$APP_PATH" "$PAYLOAD_DIR/PhoneMicIOS.app"

if [[ -e "$OUTPUT" ]]; then
  unlink "$OUTPUT"
fi

(
  cd "$STAGING_DIR"
  zip -qry -X "$OUTPUT" Payload
)

echo "Resignable Release IPA created at:"
echo "$OUTPUT"
