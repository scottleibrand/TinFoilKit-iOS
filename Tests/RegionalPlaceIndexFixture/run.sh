#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
python_cli=${1:-python3}
scratch=$(mktemp -d "${TMPDIR:-/tmp}/tfk-places.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT

"$python_cli" - "$scratch" <<'PY'
from pathlib import Path
import sqlite3
import sys

import osmium

scratch = Path(sys.argv[1])
with osmium.SimpleWriter(scratch / "places.osm.pbf") as writer:
    for item in osmium.FileProcessor("Tests/RegionalPlaceIndexFixture/places.osm"):
        writer.add(item)
with sqlite3.connect(scratch / "old.sqlite") as db:
    db.execute("PRAGMA application_id = 0x54464B50")
    db.execute("PRAGMA user_version = 2")
PY

"$python_cli" Scripts/build-regional-place-index.py "$scratch/places.osm.pbf" "$scratch/places.sqlite" \
    --region 'Synthetic test' --source https://example.org/synthetic.osm.pbf --data-version synthetic-v1 \
    --bounds -180 -90 180 90

swiftc -module-cache-path "$scratch/module-cache" Sources/TinfoilKit/RegionalPlaceIndex.swift \
    Sources/TinfoilKit/RegionalServiceCategory.swift \
    Tests/RegionalPlaceIndexFixture/VerifyRegionalPlaceIndex.swift -lsqlite3 -o "$scratch/verify"
"$scratch/verify" "$scratch/places.sqlite" "$scratch/old.sqlite"
