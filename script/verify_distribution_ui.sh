#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IOS_VIEW="$ROOT_DIR/Apps/iOS/PhoneMicIOS/PhoneMicView.swift"
DMG_PATH="${1:-$ROOT_DIR/dist/PhoneMic-dev.dmg}"

require_source_text() {
  local expected="$1"
  if ! /usr/bin/grep -Fq "$expected" "$IOS_VIEW"; then
    echo "Missing iOS settings contract: $expected" >&2
    exit 1
  fi
}

require_source_text '@State private var showsForgetMacConfirmation = false'
require_source_text '.alert("忘记此 Mac？"'
require_source_text 'Button("取消", role: .cancel)'
require_source_text 'Button("确定", role: .destructive)'
require_source_text '.buttonStyle(.borderless)'

if [[ ! -f "$DMG_PATH" ]]; then
  echo "DMG not found: $DMG_PATH" >&2
  exit 1
fi

MOUNT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/phonemic-dmg.XXXXXX")"
DMG_MOUNTED=false

cleanup() {
  if [[ "$DMG_MOUNTED" == true ]]; then
    /usr/bin/hdiutil detach "$MOUNT_DIR" -quiet || true
  fi
  /bin/rmdir "$MOUNT_DIR" 2>/dev/null || true
}
trap cleanup EXIT

/usr/bin/hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$MOUNT_DIR" >/dev/null
DMG_MOUNTED=true

[[ -d "$MOUNT_DIR/PhoneMic.app" ]] || { echo "PhoneMic.app is missing from DMG" >&2; exit 1; }
[[ -L "$MOUNT_DIR/Applications" ]] || { echo "Applications shortcut is missing from DMG" >&2; exit 1; }
[[ "$(/usr/bin/readlink "$MOUNT_DIR/Applications")" == "/Applications" ]] || {
  echo "Applications shortcut has the wrong target" >&2
  exit 1
}
[[ -f "$MOUNT_DIR/.background/PhoneMicDMGBackground.png" ]] || {
  echo "DMG background is missing" >&2
  exit 1
}
BACKGROUND_ATTRIBUTES="$(/usr/bin/xcrun GetFileInfo -a "$MOUNT_DIR/.background")"
[[ "$BACKGROUND_ATTRIBUTES" == *V* ]] || {
  echo "DMG background directory is visible in Finder" >&2
  exit 1
}
[[ -f "$MOUNT_DIR/.DS_Store" ]] || { echo "Finder layout metadata is missing" >&2; exit 1; }

echo "PhoneMic distribution UI contract passed."
