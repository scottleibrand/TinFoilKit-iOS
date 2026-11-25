#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

tools=.build/map-tools
assets=.build/map-assets
if [[ "${1:-}" == --lightweight && $# -eq 1 ]]; then
    assets=.build/lightweight/map-assets
elif [[ $# -ne 0 ]]; then
    echo "Usage: $0 [--lightweight]" >&2
    exit 2
fi
fonts="$assets/glyphs/Noto Sans Regular"
mkdir -p "$tools" "$fonts"

fetch() {
    curl --fail --silent --show-error --location --retry 2 --output "$2.partial" "$1"
    mv "$2.partial" "$2"
}

if [[ ! -d "$tools/MapLibre.xcframework" || ! -f "$tools/LICENSE.md" ]]; then
    if [[ ! -f "$tools/maplibre.zip" ]]; then
        fetch https://github.com/maplibre/maplibre-native/releases/download/ios-v6.29.0/MapLibre.dynamic.xcframework.zip "$tools/maplibre.zip"
    fi
    printf '%s  %s\n' 0963b9cebd9e3b670b1a39f82e4ffa5ab6a6343352a0fd3430b3cbce4fac9bd8 "$tools/maplibre.zip" | shasum -a 256 -c
    unzip -oq "$tools/maplibre.zip" -d "$tools"
fi
cp "$tools/LICENSE.md" "$assets/MapLibre-LICENSE.txt"

if [[ ! -f "$assets/MapLibre-iOS-LICENSE.txt" ]]; then
    if [[ ! -f "$tools/MapLibre-iOS-LICENSE.txt" ]]; then
        fetch https://raw.githubusercontent.com/maplibre/maplibre-native/ios-v6.29.0/platform/ios/LICENSE.md \
            "$tools/MapLibre-iOS-LICENSE.txt"
    fi
    printf '%s  %s\n' 88adc1c42d7b0656580d8f42d81fc0f6ec1ab12417b68c7d3a20598d9bbcea19 \
        "$tools/MapLibre-iOS-LICENSE.txt" | shasum -a 256 -c
    cp "$tools/MapLibre-iOS-LICENSE.txt" "$assets/MapLibre-iOS-LICENSE.txt"
fi

font_source=https://raw.githubusercontent.com/protomaps/basemaps-assets/028c18f713baecad011301ff7a69acc39bcc2ae7/fonts
for range in 0-255 256-511 8192-8447; do
    if [[ ! -f "$fonts/$range.pbf" ]]; then
        full_glyph=".build/map-assets/glyphs/Noto Sans Regular/$range.pbf"
        if [[ -f "$full_glyph" ]]; then
            cp "$full_glyph" "$fonts/$range.pbf"
        else
            fetch "$font_source/Noto%20Sans%20Regular/$range.pbf" "$fonts/$range.pbf"
        fi
    fi
done
if [[ ! -f "$assets/OFL.txt" ]]; then
    if [[ -f .build/map-assets/OFL.txt ]]; then
        cp .build/map-assets/OFL.txt "$assets/OFL.txt"
    else
        fetch "$font_source/OFL.txt" "$assets/OFL.txt"
    fi
fi

if [[ "$assets" == .build/lightweight/map-assets ]]; then
    exit 0
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

# Use the same immutable Source Cooperative object as the app's explored tile cache.
basemap='https://data.source.coop/protomaps/openstreetmap/v4.pmtiles?versionId=440HxKhBAVMB.cR3WUFToSUubTpDm6b7'
if [[ ! -f "$assets/seattle.pmtiles" ]]; then
    "$tools/pmtiles" extract "$basemap" "$tools/seattle.pmtiles" \
        --bbox=-122.53,47.43,-122.18,47.78 --minzoom=6 --maxzoom=15
    "$tools/pmtiles" verify "$tools/seattle.pmtiles"
    mv "$tools/seattle.pmtiles" "$assets/seattle.pmtiles"
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
