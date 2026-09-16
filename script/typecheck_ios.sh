#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export DEVELOPER_DIR

SWIFTC="$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
TYPECHECK_DIR="$ROOT_DIR/build/iOSTypecheck"

mkdir -p "$TYPECHECK_DIR"
cd "$ROOT_DIR"

"$SWIFTC" \
  -target arm64-apple-ios17.0 \
  -sdk "$SDKROOT" \
  -parse-as-library \
  -emit-module \
  -module-name PhoneMicCore \
  Sources/PhoneMicCore/AudioConstants.swift \
  Sources/PhoneMicCore/AudioPacket.swift \
  Sources/PhoneMicCore/JitterBuffer.swift \
  Sources/PhoneMicCore/LevelMeter.swift \
  Sources/PhoneMicCore/PhoneMicTrustedPeerStore.swift \
  -emit-module-path "$TYPECHECK_DIR/PhoneMicCore.swiftmodule"

"$SWIFTC" \
  -target arm64-apple-ios17.0 \
  -sdk "$SDKROOT" \
  -I "$TYPECHECK_DIR" \
  -typecheck \
  Apps/iOS/PhoneMicIOS/PhoneMicIOSApp.swift \
  Apps/iOS/PhoneMicIOS/PhoneMicView.swift \
  Apps/iOS/PhoneMicIOS/PhoneMicIOSModel.swift \
  Apps/iOS/PhoneMicIOS/MicrophoneStreamer.swift

echo "PhoneMic iOS Swift typecheck passed."
