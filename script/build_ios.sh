#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

cd "$ROOT_DIR"

if ! xcodebuild \
  -project PhoneMic.xcodeproj \
  -scheme PhoneMicIOS \
  -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$ROOT_DIR/build/XcodeDerivedData" \
  CODE_SIGNING_ALLOWED=NO \
  build
then
  echo
  echo "PhoneMic iOS build did not complete." >&2
  echo "If Xcode reports that iOS is not installed, open Xcode > Settings > Components and install the iOS platform, then rerun this script." >&2
  echo "Destination summary:" >&2
  xcodebuild -project PhoneMic.xcodeproj -scheme PhoneMicIOS -showdestinations >&2 || true
  exit 1
fi
