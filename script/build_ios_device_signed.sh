#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
DEVICE_ID="${DEVICE_ID:-}"
CONFIGURATION="${CONFIGURATION:-Debug}"
INSTALL="${INSTALL:-0}"
DEVICETCL="$DEVELOPER_DIR/usr/bin/devicectl"
export DEVELOPER_DIR

cd "$ROOT_DIR"

if [[ -z "$DEVELOPMENT_TEAM" ]]; then
  cat >&2 <<'MSG'
Missing DEVELOPMENT_TEAM.

Set your Apple Development Team ID, for example:
  DEVELOPMENT_TEAM=ABCDE12345 ./script/build_ios_device_signed.sh

You can also open PhoneMic.xcodeproj in Xcode, select PhoneMicIOS, and choose your Team under Signing & Capabilities.
MSG
  exit 2
fi

if ! security find-identity -p codesigning -v | grep -E 'Apple Development|iPhone Developer|Apple Distribution|iPhone Distribution' >/dev/null; then
  cat >&2 <<'MSG'
No valid Apple code-signing identity was found in this macOS keychain.

Open Xcode > Settings > Accounts, sign in with your Apple ID, select your team, and let Xcode create/download an Apple Development certificate.
Then rerun this script.
MSG
  exit 3
fi

if [[ -n "$DEVICE_ID" ]]; then
  if [[ ! -x "$DEVICETCL" ]]; then
    DEVICETCL="$(xcrun -f devicectl)"
  fi
  if ! "$DEVICETCL" list devices | grep "$DEVICE_ID" | grep -v unavailable >/dev/null; then
    cat >&2 <<MSG
Device $DEVICE_ID is not available to Xcode.

Connect and unlock the iPhone, trust this Mac, enable Developer Mode if prompted, then check:
  $DEVICETCL list devices
MSG
    exit 4
  fi
  DESTINATION="id=$DEVICE_ID"
else
  DESTINATION="generic/platform=iOS"
fi

xcodebuild \
  -project PhoneMic.xcodeproj \
  -scheme PhoneMicIOS \
  -configuration "$CONFIGURATION" \
  -destination "$DESTINATION" \
  -derivedDataPath "$ROOT_DIR/build/XcodeDerivedDataSigned" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CODE_SIGNING_ALLOWED=YES \
  build

APP_PATH="$ROOT_DIR/build/XcodeDerivedDataSigned/Build/Products/$CONFIGURATION-iphoneos/PhoneMicIOS.app"

if [[ "$INSTALL" == "1" ]]; then
  if [[ -z "$DEVICE_ID" ]]; then
    echo "INSTALL=1 requires DEVICE_ID=<device identifier>." >&2
    exit 5
  fi
  if [[ ! -x "$DEVICETCL" ]]; then
    DEVICETCL="$(xcrun -f devicectl)"
  fi
  "$DEVICETCL" device install app --device "$DEVICE_ID" "$APP_PATH"
fi

echo "Signed build created at:"
echo "$APP_PATH"
