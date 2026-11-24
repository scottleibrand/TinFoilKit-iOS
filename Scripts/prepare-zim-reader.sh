#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."

reader_revision=cbafcb41da64c390c7889b122c677f23bcde8dc5
fixture_revision=2edf72096208e60c82b6ebbe313baa552cc6af52
reader=.build/zimru
fixture=.build/fixtures/climate.zim
case "${1:-simulator}" in
    simulator) target=aarch64-apple-ios-sim ;;
    device) target=aarch64-apple-ios ;;
    *) echo "Usage: $0 [simulator|device]" >&2; exit 2 ;;
esac

mkdir -p .build/CTFKReader .build/fixtures
if [[ ! -d "$reader/.git" ]]; then
    git clone https://github.com/jasontitus/zimru.git "$reader"
fi
if [[ "$(git -C "$reader" rev-parse HEAD)" != "$reader_revision" ]]; then
    git -C "$reader" checkout --detach "$reader_revision"
fi

cargo build --manifest-path ReaderBridge/Cargo.toml --locked --release \
    --target "$target" --target-dir .build/reader-bridge
cp ReaderBridge/include/tfk_reader.h .build/CTFKReader/
cat > .build/CTFKReader/module.modulemap <<'MODULE'
module CTFKReader {
    header "tfk_reader.h"
    export *
}
MODULE

if [[ ! -f "$fixture" ]]; then
    curl --fail --silent --show-error --location --output "$fixture.partial" \
        "https://raw.githubusercontent.com/openzim/zim-testing-suite/$fixture_revision/data/noTitleListingV0/wikipedia_en_climate_change_mini_2024-06.zim"
    mv "$fixture.partial" "$fixture"
fi

cargo metadata --manifest-path ReaderBridge/Cargo.toml --locked --format-version 1 \
    --filter-platform "$target" | python3 Scripts/prepare-notices.py .build/notices
if [[ ! -f .build/notices/SwiftSoup.txt ]]; then
    curl --fail --silent --show-error --location --output .build/SwiftSoup-LICENSE.partial \
        https://raw.githubusercontent.com/scinfu/SwiftSoup/2.14.4/LICENSE
    mv .build/SwiftSoup-LICENSE.partial .build/notices/SwiftSoup.txt
fi

xcodegen generate
