"""Build a searchable SQLite index from extracted map place records."""

import argparse
import json
import sqlite3
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("places_json", type=Path)
    parser.add_argument("index", type=Path)
    args = parser.parse_args()
    places = json.loads(args.places_json.read_bytes())
    if not places:
        raise SystemExit("The place export has no data.")

    temporary = args.index.with_suffix(".partial")
    temporary.unlink(missing_ok=True)
    try:
        with sqlite3.connect(temporary) as db:
            db.execute("CREATE VIRTUAL TABLE places USING fts5(name, kind, latitude UNINDEXED, longitude UNINDEXED)")
            db.executemany(
                "INSERT INTO places VALUES (:name, :kind, :latitude, :longitude)",
                places,
            )
        temporary.replace(args.index)
    finally:
        temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
