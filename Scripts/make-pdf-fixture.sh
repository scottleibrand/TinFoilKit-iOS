#!/bin/bash
# Regenerates Tests/ZIMArchiveTests/Fixtures/pdf-collection.zim with zimru's zimwriterfs.
# Run Scripts/prepare-zim-reader.sh first so .build/zimru is checked out.
set -euo pipefail

cd "$(dirname "$0")/.."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cargo build --manifest-path .build/zimru/Cargo.toml --locked --release --bin zimwriterfs \
    --target-dir .build/zimru-host
python3 -I Scripts/make-pdf-fixture.py "$work/source"
mkdir -p Tests/ZIMArchiveTests/Fixtures
rm -f Tests/ZIMArchiveTests/Fixtures/pdf-collection.zim
.build/zimru-host/release/zimwriterfs --without-indexes \
    -w index.html -I illustration.png -l eng -n tinfoilkit_pdf_fixture -t "Fixture manuals" \
    -d "PDF collection for library tests" -c "Tinfoil Kit" -p "Tinfoil Kit" \
    "$work/source" Tests/ZIMArchiveTests/Fixtures/pdf-collection.zim
