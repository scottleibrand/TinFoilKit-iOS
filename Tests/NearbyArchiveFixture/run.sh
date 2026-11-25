#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
output="$(mktemp -d)"
trap 'rm -rf "$output"' EXIT
xcrun swiftc -module-cache-path "$output/module-cache" -o "$output/verify" \
    Tests/NearbyArchiveFixture/VerifyNearbyArchive.swift \
    Sources/TinfoilKit/Nearby{ArchiveFiles,ArchiveTransfer,Discovery,PublicManifest,PublicReference,PublicResume,PublicTLS,PublicTransfer}.swift
"$output/verify" "$output"
