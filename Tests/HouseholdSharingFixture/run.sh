#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="$(mktemp -d)"
trap 'rm -rf "$output"' EXIT
xcrun swiftc -module-cache-path "$output/module-cache" -o "$output/verify" \
    Tests/HouseholdSharingFixture/VerifyHouseholdSharing.swift \
    Sources/TinfoilKit/HouseholdSharing.swift \
    Sources/TinfoilKit/Household.swift \
    Sources/TinfoilKit/MapCoordinateText.swift
"$output/verify"
