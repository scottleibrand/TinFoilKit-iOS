#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="$(mktemp -d)"
sender=""
cleanup() {
    if [[ -n "$sender" ]]; then kill "$sender" 2>/dev/null || true; fi
    rm -rf "$output"
}
trap cleanup EXIT
xcrun swiftc -module-cache-path "$output/module-cache" -o "$output/verify" \
    Tests/NearbyPublicFixture/VerifyNearbyPublic.swift \
    Sources/TinfoilKit/Nearby{Discovery,PublicManifest,PublicReference,PublicTLS,PublicTransfer}.swift
seed=Resources/NearbyPublic/household-check-in-v1.txt


"$output/verify" serve "$output/first" "$seed" &
sender=$!
"$output/verify" disabled "$output/disabled" -
"$output/verify" receive "$output/second" -
kill "$sender"
wait "$sender" 2>/dev/null || true

"$output/verify" serve "$output/second" - &
sender=$!
"$output/verify" receive "$output/third" -
echo "Verified opt-in public transfer, offline persistence, and automatic relay."
kill "$sender"
wait "$sender" 2>/dev/null || true

"$output/verify" serve-draining "$output/third" - &
sender=$!
"$output/verify" receive-draining "$output/fourth" -
