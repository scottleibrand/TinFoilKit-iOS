"""Build an offline place index from an OpenStreetMap PBF extract."""

import argparse
import sqlite3
import tempfile
from contextlib import closing
from pathlib import Path
from urllib.parse import urlsplit

import osmium


APPLICATION_ID = 0x54464B50  # TFKP
SCHEMA_VERSION = 1
ATTRIBUTION = "© OpenStreetMap contributors"
LICENSE_URL = "https://www.openstreetmap.org/copyright"

SERVICE_TAGS = {
    ("amenity", "hospital"): "hospital",
    ("healthcare", "hospital"): "hospital",
    ("amenity", "clinic"): "urgent_care",
    ("amenity", "doctors"): "urgent_care",
    ("healthcare", "urgent_care"): "urgent_care",
    ("healthcare", "clinic"): "urgent_care",
    ("healthcare", "doctor"): "urgent_care",
    ("amenity", "pharmacy"): "pharmacy",
    ("shop", "chemist"): "pharmacy",
    ("amenity", "police"): "police",
    ("amenity", "fire_station"): "fire_station",
    ("amenity", "shelter"): "shelter",
    ("emergency", "assembly_point"): "shelter",
    ("social_facility", "shelter"): "shelter",
    ("amenity", "fuel"): "gas",
    ("shop", "supermarket"): "grocery",
    ("shop", "grocery"): "grocery",
    ("shop", "convenience"): "grocery",
    ("shop", "hardware"): "hardware",
    ("shop", "doityourself"): "hardware",
    ("amenity", "drinking_water"): "drinking_water",
    ("man_made", "water_well"): "drinking_water",
}
SERVICE_KEYS = tuple(dict.fromkeys(key for key, _ in SERVICE_TAGS))
SERVICE_LABELS = {
    "hospital": "Hospital",
    "urgent_care": "Urgent care clinic",
    "pharmacy": "Pharmacy",
    "police": "Police",
    "fire_station": "Fire station",
    "shelter": "Shelter",
    "gas": "Gas station fuel",
    "grocery": "Grocery supermarket",
    "hardware": "Hardware",
    "drinking_water": "Drinking water",
}
PLACE_KEYS = ("place", "amenity", "shop", "healthcare", "leisure", "tourism", "railway", "aeroway")


def place_data(tags):
    if not tags:
        return None
    name = tags.get("name") or tags.get("name:en")
    number = tags.get("addr:housenumber")
    street = tags.get("addr:street") or tags.get("addr:place")
    locality = (tags.get("addr:city") or tags.get("addr:town")
                or tags.get("addr:village") or tags.get("addr:hamlet"))
    street_address = " ".join(part for part in (number, street) if part)
    address = ", ".join(part for part in (street_address, locality, tags.get("addr:postcode")) if part)
    service_values = {key: tags.get(key) for key in SERVICE_KEYS}
    category = next((value for (key, tag), value in SERVICE_TAGS.items() if service_values[key] == tag), None)
    if category is None:
        kind = next((tags[key] for key in PLACE_KEYS if tags.get(key) not in (None, "", "yes", "no")), None)
        if not (number and street) and not (name and kind):
            return None
        category = kind or "address"
    label = SERVICE_LABELS.get(category, category.replace("_", " ").capitalize())
    return name or street_address or label, category, label, address


def center(nodes):
    # Unwrap around the first vertex so small ways crossing the date line stay local.
    west = south = float("inf")
    east = north = float("-inf")
    anchor = None
    for node in nodes:
        if not node.location.valid():
            continue
        lon, lat = node.lon, node.lat
        if anchor is None:
            anchor = lon
        lon = anchor + (lon - anchor + 180) % 360 - 180
        west, east = min(west, lon), max(east, lon)
        south, north = min(south, lat), max(north, lat)
    if anchor is None:
        return None
    return ((west + east) / 2 + 180) % 360 - 180, (south + north) / 2


class PlaceCollector(osmium.SimpleHandler):
    def __init__(self, database, bounds):
        super().__init__()
        self.database = database
        self.bounds = bounds
        self.rows = []

    def node(self, node):
        data = place_data(node.tags)
        if data and node.location.valid():
            self.add("n", node.id, data, node.lon, node.lat)

    def way(self, way):
        data = place_data(way.tags)
        if data:
            location = center(way.nodes)
            if location is not None:
                self.add("w", way.id, data, *location)

    def area(self, area):
        # Closed ways have already been handled. Include multipolygon relations too.
        if area.from_way():
            return
        data = place_data(area.tags)
        if data:
            location = center(node for ring in area.outer_rings() for node in ring)
            if location is not None:
                self.add("r", area.orig_id(), data, *location)

    def add(self, osm_type, osm_id, data, lon, lat):
        if self.bounds:
            west, south, east, north = self.bounds
            within_longitude = west <= lon <= east if west <= east else lon >= west or lon <= east
            if not (within_longitude and south <= lat <= north):
                return
        self.rows.append((osm_type, osm_id, *data, lat, lon))
        if len(self.rows) >= 8192:
            self.flush()

    def flush(self):
        self.database.executemany("""
            INSERT INTO places(osm_type, osm_id, title, category, category_words, address, latitude, longitude)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """, self.rows)
        self.rows.clear()


def build(args):
    data_version = args.data_version
    if not data_version:
        with closing(osmium.io.Reader(args.osm_extract)) as reader:
            data_version = reader.header().get("osmosis_replication_timestamp")

    # Keep the old index usable until SQLite has closed the complete replacement.
    with tempfile.TemporaryDirectory(prefix=".places-", dir=args.index.parent) as directory:
        temporary = Path(directory) / "places.sqlite"
        db = sqlite3.connect(temporary)
        try:
            db.executescript(f"""
                PRAGMA application_id = {APPLICATION_ID};
                PRAGMA user_version = {SCHEMA_VERSION};
                CREATE TABLE metadata(key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
                CREATE TABLE places(
                    id INTEGER PRIMARY KEY,
                    osm_type TEXT NOT NULL,
                    osm_id INTEGER NOT NULL,
                    title TEXT NOT NULL,
                    category TEXT NOT NULL,
                    category_words TEXT NOT NULL,
                    address TEXT NOT NULL,
                    latitude REAL NOT NULL,
                    longitude REAL NOT NULL
                );
                CREATE VIRTUAL TABLE place_search USING fts5(
                    title, address, category_words, content='places', content_rowid='id'
                );
                CREATE VIRTUAL TABLE place_bounds USING rtree(
                    id, min_latitude, max_latitude, min_longitude, max_longitude
                );
                """)
            with db:
                collector = PlaceCollector(db, args.bounds)
                collector.apply_file(str(args.osm_extract), locations=True, idx=args.node_index)
                collector.flush()
                count = db.execute("SELECT count(*) FROM places").fetchone()[0]
                if not count:
                    raise ValueError("The extract contains no supported places in this region.")
                db.execute("INSERT INTO place_search(place_search) VALUES ('rebuild')")
                db.execute("""
                    INSERT INTO place_bounds SELECT id, latitude, latitude, longitude, longitude FROM places
                    """)
                metadata = {
                    "region": args.region,
                    "source": args.source,
                    "attribution": ATTRIBUTION,
                    "license": "ODbL-1.0",
                    "licenseURL": LICENSE_URL,
                    "placeCount": str(count),
                }
                if args.bounds:
                    metadata["bounds"] = ",".join(map(str, args.bounds))
                if data_version:
                    metadata["dataVersion"] = data_version
                db.executemany("INSERT INTO metadata VALUES (?, ?)", metadata.items())
        finally:
            db.close()
        temporary.replace(args.index)
    print(f"Built {args.region}: {count:,} places. {ATTRIBUTION} · ODbL 1.0")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("osm_extract", type=Path, help="Publisher's OSM PBF extract")
    parser.add_argument("index", type=Path, help="Output SQLite index")
    parser.add_argument("--region", required=True, help="Display name of the covered region")
    parser.add_argument("--source", required=True, help="HTTPS URL identifying the publisher's dataset")
    parser.add_argument("--data-version", help="Publisher version or date (defaults to the PBF replication timestamp)")
    parser.add_argument("--bounds", nargs=4, type=float, metavar=("WEST", "SOUTH", "EAST", "NORTH"))
    parser.add_argument("--node-index", default="flex_mem", help="PyOsmium node location index (default: flex_mem)")
    args = parser.parse_args()
    source = urlsplit(args.source)
    if source.scheme != "https" or not source.hostname or source.username is not None:
        parser.error("--source must be an HTTPS URL identifying the publisher's dataset.")
    if not args.region.strip():
        parser.error("--region cannot be blank.")
    if args.osm_extract.resolve() == args.index.resolve():
        parser.error("The SQLite index must have a different path from the extract.")
    if args.bounds:
        west, south, east, north = args.bounds
        if not (-180 <= west <= 180 and -180 <= east <= 180 and west != east and -90 <= south < north <= 90):
            parser.error("--bounds must be valid west, south, east and north coordinates.")
    build(args)


if __name__ == "__main__":
    main()
