#!/usr/bin/env bash
set -euo pipefail

route_scripts="$(cd "$(dirname "$0")" && pwd)"
repo_root="$(cd "$route_scripts/../.." && pwd)"
work_dir="$repo_root/.build/valhalla-probe/apple"
framework="$repo_root/.build/routing/TFKValhalla.xcframework"

mkdir -p "$work_dir"
if [[ ! -f "$framework/Info.plist" ]]; then
    bash "$route_scripts/prepare-apple-routing.sh"
fi

build_probe() {
    local sdk="$1" target="$2" slice="$framework/$3" name="$4"
    xcrun --sdk "$sdk" clang++ -std=c++20 --target="$target" \
        -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" -isystem "$slice/Headers" \
        "$route_scripts/valhalla_probe.cpp" "$slice/libTFKValhalla.a" -lz -framework CoreFoundation \
        -o "$work_dir/$name"
    xcrun vtool -show-build "$work_dir/$name"
}

build_probe iphoneos arm64-apple-ios17.0 ios-arm64 iphoneos-valhalla-probe
build_probe iphonesimulator arm64-apple-ios17.0-simulator ios-arm64_x86_64-simulator iphonesimulator-valhalla-probe
build_probe iphonesimulator x86_64-apple-ios17.0-simulator ios-arm64_x86_64-simulator iphonesimulator-x86_64-valhalla-probe
