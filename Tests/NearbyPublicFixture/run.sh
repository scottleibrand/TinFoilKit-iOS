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
    Sources/TinfoilKit/Nearby{Discovery,PublicManifest,PublicReference,PublicResume,PublicTLS,PublicTransfer}.swift
seed=Resources/NearbyPublic/household-check-in-v1.txt


"$output/verify" serve "$output/first" "$seed" &
sender=$!
"$output/verify" disabled "$output/disabled" -
"$output/verify" receive "$output/second" -
"$output/verify" receive-checkpoint "$output/resumed" - "$seed"
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
kill "$sender"
wait "$sender" 2>/dev/null || true

log=Resources/NearbyPublic/neighborhood-status-log-v1.txt
"$output/verify" serve-catalog "$output/catalog-source" "$seed" "$log" &
sender=$!
"$output/verify" receive-catalog "$output/catalog-receiver" -
cmp "$seed" "$output/catalog-receiver/household-check-in-v1.txt"
cmp "$log" "$output/catalog-receiver/neighborhood-status-log-v1.txt"
echo "Verified both catalog references on one Nearby listener."
