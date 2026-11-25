#!/bin/bash
# Build the pinned, deterministic Nearby seed. Run prepare-zim-reader.sh once
# to populate the pinned source checkout for the writer.
set -euo pipefail

cd "$(dirname "$0")/.."
reader=.build/zimru
reader_revision=cbafcb41da64c390c7889b122c677f23bcde8dc5
destination=${1:-Resources/NearbyPublic/tinfoil-kit-offline-starter_2026-11.zim}
if [[ "$(git -C "$reader" rev-parse HEAD)" != "$reader_revision" ]] ||
   ! git -C "$reader" diff --quiet HEAD; then
    echo "The pinned zimru writer checkout is required. Run Scripts/prepare-zim-reader.sh first." >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cargo build --manifest-path "$reader/Cargo.toml" --locked --release --lib --target-dir .build/zimru-host
rustc --edition=2021 Scripts/build-nearby-starter.rs \
    --extern zimru=.build/zimru-host/release/libzimru.rlib \
    -L dependency=.build/zimru-host/release/deps -o "$work/build-nearby-starter"
"$work/build-nearby-starter" "$work/seed.zim"
mv "$work/seed.zim" "$destination"
