#!/usr/bin/env bash
set -euo pipefail

scripts="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$scripts/../.." && pwd)"
output="$root/.build/routing"
cache="$output/cache"
mkdir -p "$cache"
scratch="$(mktemp -d "$output/prepare.XXXXXXXX")"
trap 'rm -rf "$scratch"' EXIT

release=0.6.6
mobile_revision=d03c3f51925f9e0211013a6e90a69dd216654810
archive_hash=b28e73f6d314fa7fea9f27f1ce8683867f3afec920411d35dddeb8419bbc5518
timezone_hash=0d28b24fbbe940be9e0522086358ba74a438e4d81d2da4a2d290db929b7a8649
configuration_hash=d1c1d505ac15ba180515df42639c15d310767bb9365525268beaa7836611b6a6

fetch() {
    local url="$1" destination="$2"
    if [[ ! -f "$destination" ]]; then
        curl -fLsS --retry 2 --max-time 180 "$url" -o "$destination.partial"
        mv "$destination.partial" "$destination"
    fi
}

check() {
    printf '%s  %s\n' "$1" "$2" | shasum -a 256 --check -
}

archive="$cache/valhalla-wrapper-$release.zip"
probe_archive="$root/.build/valhalla-probe/apple/valhalla-wrapper.zip"
if [[ ! -f "$archive" && -f "$probe_archive" ]]; then
    cp "$probe_archive" "$archive"
fi
fetch "https://github.com/Rallista/valhalla-mobile/releases/download/$release/valhalla-wrapper.xcframework.zip" "$archive"
check "$archive_hash" "$archive"
unzip -oq "$archive" -d "$scratch"
upstream="$scratch/valhalla-wrapper.xcframework"

timezone="$cache/iana-2025b.tar"
probe_timezone="$root/.build/valhalla-probe/mobile/apple/Sources/Valhalla/SupportData/tzdata.tar"
if [[ ! -f "$timezone" && -f "$probe_timezone" ]]; then
    cp "$probe_timezone" "$timezone"
fi
fetch "https://raw.githubusercontent.com/Rallista/valhalla-mobile/$mobile_revision/apple/Sources/Valhalla/SupportData/tzdata.tar" "$timezone"
check "$timezone_hash" "$timezone"

resources="$scratch/Routing"
mkdir -p "$resources/tzdata" "$resources/Notices" "$scratch/Headers" "$scratch/Device" "$scratch/Simulator"
configuration="$cache/valhalla-mobile-$release-default.json"
probe_configuration="$root/.build/valhalla-probe/mobile/apple/Sources/Valhalla/SupportData/default.json"
if [[ ! -f "$configuration" && -f "$probe_configuration" ]]; then
    cp "$probe_configuration" "$configuration"
fi
fetch "https://raw.githubusercontent.com/Rallista/valhalla-mobile/$mobile_revision/apple/Sources/Valhalla/SupportData/default.json" "$configuration"
check "$configuration_hash" "$configuration"
cp "$configuration" "$resources/default.json"
tar -xf "$timezone" -C "$resources/tzdata" \
    ./version ./LICENSE ./africa ./antarctica ./asia ./australasia ./backward \
    ./etcetera ./europe ./northamerica ./southamerica ./leapseconds
[[ "$(cat "$resources/tzdata/version")" == 2025b ]]
cp "$resources/tzdata/LICENSE" "$resources/Notices/IANA-tzdb-2025b.txt"
cp "$scripts/notice-sources.tsv" "$resources/Notices/Sources.txt"
cp "$root/LICENSE" "$resources/Notices/TinfoilKit-MIT.txt"

while read -r name source extract; do
    fetch "$source" "$cache/$name"
    if [[ "$extract" == prefix ]]; then
        awk '!started && (/^[[:space:]]*$/ || /^#(ifndef|define)[[:space:]]/) { next }
             !started && substr($0, 1, 2) == "/*" { started=1; block=1 }
             block { print; if (index($0, "*/")) exit; next }
             substr($0, 1, 2) == "//" { started=1; print; next }
             started && /^[[:space:]]*$/ { print; next } { exit }' \
            "$cache/$name" > "$resources/Notices/$name"
    else
        cp "$cache/$name" "$resources/Notices/$name"
    fi
    [[ -s "$resources/Notices/$name" ]]
done < "$scripts/notice-sources.tsv"

cp "$scripts/valhalla_bridge.h" "$scratch/Headers/"
cat > "$scratch/Headers/module.modulemap" <<'MODULE'
module TFKValhalla {
    header "valhalla_bridge.h"
    export *
}
MODULE

device="$upstream/ios-arm64"
simulator="$upstream/ios-arm64_x86_64-simulator"
compile() {
    local sdk="$1" target="$2" headers="$3" object="$4"
    xcrun --sdk "$sdk" clang++ -std=c++20 -O2 --target="$target" \
        -isysroot "$(xcrun --sdk "$sdk" --show-sdk-path)" -isystem "$headers" \
        -c "$scripts/valhalla_bridge.cpp" -o "$object"
}
compile iphoneos arm64-apple-ios17.0 "$device/Headers" "$scratch/device.o"
compile iphonesimulator arm64-apple-ios17.0-simulator "$simulator/Headers" "$scratch/simulator-arm64.o"
compile iphonesimulator x86_64-apple-ios17.0-simulator "$simulator/Headers" "$scratch/simulator-x86_64.o"

xcrun lipo -create "$scratch/simulator-arm64.o" "$scratch/simulator-x86_64.o" -output "$scratch/simulator.o"
xcrun libtool -static -o "$scratch/Device/libTFKValhalla.a" "$scratch/device.o" "$device/libvalhalla_all.a"
xcrun libtool -static -o "$scratch/Simulator/libTFKValhalla.a" "$scratch/simulator.o" "$simulator/libvalhalla_all.a"
xcodebuild -create-xcframework \
    -library "$scratch/Device/libTFKValhalla.a" -headers "$scratch/Headers" \
    -library "$scratch/Simulator/libTFKValhalla.a" -headers "$scratch/Headers" \
    -output "$scratch/TFKValhalla.xcframework"

for artifact in TFKValhalla.xcframework Routing; do
    rm -rf "$output/$artifact"
    mv "$scratch/$artifact" "$output/$artifact"
done
