#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILE="$ROOT_DIR/Sources/PhoneMicMac/MacAudioReceiver.swift"

ownership_guards="$(grep -c 'guard self\.connection === connection else' "$FILE" || true)"
stale_global_suppression="$(grep -c 'suppressNextCancelledEvent' "$FILE" || true)"
retrying_retirements="$(grep -c 'retireConnection(connection, reconnectTransport:' "$FILE" || true)"

if [[ "$ownership_guards" -lt 2 ]]; then
  echo "MacAudioReceiver: expected ownership guards for connection state and audio receive callbacks" >&2
  exit 1
fi

if [[ "$stale_global_suppression" -ne 0 ]]; then
  echo "MacAudioReceiver: global cancellation suppression can affect a replacement connection" >&2
  exit 1
fi

if [[ "$retrying_retirements" -lt 3 ]]; then
  echo "MacAudioReceiver: stream handshake and receive failures must retire the active connection with retry" >&2
  exit 1
fi

echo "MacAudioReceiver protects replacement connections from stale callbacks."
