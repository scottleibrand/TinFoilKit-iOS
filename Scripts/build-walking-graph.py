"""Build a regional pedestrian graph from an OpenStreetMap PBF extract."""

import argparse
import sqlite3
from pathlib import Path

import osmium

WALKABLE = {
    "footway", "pedestrian", "path", "steps", "track", "living_street", "residential",
    "unclassified", "service", "tertiary", "tertiary_link", "secondary", "secondary_link",
    "primary", "primary_link",
}
ALLOWED = {"yes", "designated", "permissive", "official"}
RESTRICTED = {"no", "private", "customers", "permit", "delivery"}
WEST, SOUTH, EAST, NORTH = -122.53, 47.43, -122.18, 47.78
PRECISION = 10_000_000


class WalkingGraph(osmium.SimpleHandler):
    def __init__(self, database):
        super().__init__()
        self.database = database
        self.blocked = set()
        self.nodes = {}
        self.edges = set()

    def node(self, node):
        tags = node.tags
        foot = tags.get("foot")
        if foot in RESTRICTED or (foot not in ALLOWED and tags.get("access") in RESTRICTED):
            self.blocked.add(node.id)
        elif foot not in ALLOWED and tags.get("barrier") in {"wall", "fence", "hedge", "stile"}:
            self.blocked.add(node.id)

    def way(self, way):
        tags = way.tags
        foot = tags.get("foot")
        if tags.get("highway") not in WALKABLE or tags.get("area") == "yes" or foot in RESTRICTED:
            return
        if foot not in ALLOWED and tags.get("access") in RESTRICTED:
            return
        previous = None
        for node in way.nodes:
            location = node.location
            if not location.valid() or node.ref in self.blocked:
                previous = None
                continue
            if not (WEST <= location.lon <= EAST and SOUTH <= location.lat <= NORTH):
                previous = None
                continue

            current = (node.ref, round(location.lat * PRECISION), round(location.lon * PRECISION))
            if previous is not None and previous[0] != current[0]:
                self.nodes[previous[0]] = previous
                self.nodes[current[0]] = current
                direction = tags.get("oneway:foot")
                if direction != "-1":
                    self.edges.add((previous[0], current[0]))
                if direction not in {"yes", "1", "true"}:
                    self.edges.add((current[0], previous[0]))
            previous = current
        if len(self.edges) >= 8192:
            self.flush()

    def flush(self):
        self.database.executemany("INSERT OR IGNORE INTO nodes VALUES (?, ?, ?)", self.nodes.values())
        self.database.executemany("INSERT OR IGNORE INTO edges VALUES (?, ?)", self.edges)
        self.nodes.clear()
        self.edges.clear()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("osm_extract", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    staging = args.output.with_suffix(".partial")
    staging.unlink(missing_ok=True)
    database = sqlite3.connect(staging)
    try:
        with database:
            database.executescript("""
                PRAGMA journal_mode=OFF;
                CREATE TABLE nodes(id INTEGER PRIMARY KEY, latitude INTEGER NOT NULL, longitude INTEGER NOT NULL);
                CREATE TABLE edges(origin INTEGER, destination INTEGER, PRIMARY KEY(origin, destination)) WITHOUT ROWID;
                CREATE INDEX nodes_latitude ON nodes(latitude);
            """)
            graph = WalkingGraph(database)
            graph.apply_file(args.osm_extract, locations=True, idx="flex_mem")
            graph.flush()
            nodes = database.execute("SELECT count(*) FROM nodes").fetchone()[0]
            edges = database.execute("SELECT count(*) FROM edges").fetchone()[0]
            if nodes == 0 or edges == 0:
                raise RuntimeError("The extract contains no pedestrian routes in this region.")
            print(f"Built a Seattle walking graph with {nodes:,} nodes and {edges:,} directed edges.")
        database.close()
        staging.replace(args.output)
    finally:
        database.close()
        staging.unlink(missing_ok=True)


if __name__ == "__main__":
    main()
