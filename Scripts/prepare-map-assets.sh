#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

tools=.build/map-tools
assets=.build/map-assets
fonts="$assets/glyphs/Noto Sans Regular"
mkdir -p "$tools" "$fonts"

fetch() {
    curl --fail --silent --show-error --location --retry 2 --output "$2.partial" "$1"
    mv "$2.partial" "$2"
}

if [[ ! -d "$tools/MapLibre.xcframework" || ! -f "$assets/MapLibre-LICENSE.txt" ]]; then
    if [[ ! -f "$tools/maplibre.zip" ]]; then
        fetch https://github.com/maplibre/maplibre-native/releases/download/ios-v6.29.0/MapLibre.dynamic.xcframework.zip "$tools/maplibre.zip"
    fi
    printf '%s  %s\n' 0963b9cebd9e3b670b1a39f82e4ffa5ab6a6343352a0fd3430b3cbce4fac9bd8 "$tools/maplibre.zip" | shasum -a 256 -c
    unzip -oq "$tools/maplibre.zip" -d "$tools"
    cp "$tools/LICENSE.md" "$assets/MapLibre-LICENSE.txt"
fi

if [[ ! -x "$tools/pmtiles" ]]; then
    case "$(uname -m)" in
        arm64)
            architecture=arm64
            digest=40528f7f616fcbf91207cd48c8fc023d213f6d86c0cbf1f748732803d1880f3d
            ;;
        x86_64)
            architecture=x86_64
            digest=1f0dc02eee6c58312dd6c509faee1b5c32f0596568af1bf51f1b034e7a88a65b
            ;;
        *) echo "This script requires an Apple Silicon or Intel Mac." >&2; exit 2 ;;
    esac
    fetch "https://github.com/protomaps/go-pmtiles/releases/download/v1.31.2/go-pmtiles-1.31.2_Darwin_${architecture}.zip" "$tools/pmtiles.zip"
    printf '%s  %s\n' "$digest" "$tools/pmtiles.zip" | shasum -a 256 -c
    unzip -o "$tools/pmtiles.zip" -d "$tools"
fi

if [[ ! -f "$assets/seattle.pmtiles" ]]; then
    "$tools/pmtiles" extract https://build.protomaps.com/20261124.pmtiles "$tools/seattle.pmtiles" \
        --bbox=-122.53,47.43,-122.18,47.78 --minzoom=6 --maxzoom=15
    "$tools/pmtiles" verify "$tools/seattle.pmtiles"
    mv "$tools/seattle.pmtiles" "$assets/seattle.pmtiles"
fi

font_source=https://raw.githubusercontent.com/protomaps/basemaps-assets/028c18f713baecad011301ff7a69acc39bcc2ae7/fonts
for range in 0-255 256-511 8192-8447; do
    if [[ ! -f "$fonts/$range.pbf" ]]; then
        fetch "$font_source/Noto%20Sans%20Regular/$range.pbf" "$fonts/$range.pbf"
    fi
done
if [[ ! -f "$assets/OFL.txt" ]]; then
    fetch "$font_source/OFL.txt" "$assets/OFL.txt"
fi

if [[ ! -f "$assets/seattle-places.sqlite" ]]; then
    if [[ ! -d "$tools/node/node_modules/@mapbox/vector-tile" ]]; then
        npm install --prefix "$tools/node" --ignore-scripts --no-audit --no-fund \
            --save-exact @mapbox/vector-tile@2.0.4 pbf@4.0.1
    fi
    node Scripts/extract-map-places.mjs "$tools/pmtiles" "$assets/seattle.pmtiles" \
        "$tools/seattle-places.json" "$tools/node"
    python3 Scripts/index-map-places.py "$tools/seattle-places.json" "$assets/seattle-places.sqlite"
fi
