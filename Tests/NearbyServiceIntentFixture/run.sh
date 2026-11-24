#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tfk-service-intent.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT

swiftc -module-cache-path "$scratch/module-cache" \
    Sources/TinfoilKit/RegionalServiceCategory.swift \
    Sources/TinfoilKit/NearbyServiceIntent.swift \
    Tests/NearbyServiceIntentFixture/VerifyNearbyServiceIntent.swift \
    -o "$scratch/verify"
"$scratch/verify"
