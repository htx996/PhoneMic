#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FILES=(
  "$ROOT_DIR/Apps/iOS/PhoneMicIOS/MicrophoneStreamer.swift"
  "$ROOT_DIR/Sources/PhoneMicMac/MacAudioReceiver.swift"
)
EXPECTED_LOOPBACK_BLOCKS=(3 2)

for index in "${!FILES[@]}"; do
  file="${FILES[$index]}"
  tcp_parameters="$(grep -c 'let parameters = NWParameters\.tcp' "$file" || true)"
  direct_connections="$(grep -c 'parameters\.preferNoProxies = true' "$file" || true)"
  loopback_blocks="$(grep -c 'parameters\.prohibitedInterfaceTypes = \[\.loopback\]' "$file" || true)"

  if [[ "$tcp_parameters" -ne "$direct_connections" ]]; then
    echo "$(basename "$file"): $tcp_parameters TCP parameter sets, $direct_connections direct-connection policies" >&2
    exit 1
  fi

  if [[ "$loopback_blocks" -ne "${EXPECTED_LOOPBACK_BLOCKS[$index]}" ]]; then
    echo "$(basename "$file"): expected ${EXPECTED_LOOPBACK_BLOCKS[$index]} Wi-Fi loopback blocks, found $loopback_blocks" >&2
    exit 1
  fi
done

echo "All PhoneMic local TCP connections bypass system proxies."
