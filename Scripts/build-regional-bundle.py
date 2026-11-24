#!/usr/bin/env python3
"""Build or verify a regional catalog bundle of place, routing and optional basemap artifacts."""

import argparse
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import struct
import subprocess
import sys
import tempfile
from urllib.parse import urlsplit


SCRIPTS = Path(__file__).resolve().parent
ASSETS = {"places": "places.sqlite", "routing": "routing.tfkroute"}
BASEMAP_NAME = "basemap.pmtiles"
BASEMAP_FIELDS = ("dataVersion", "source", "license", "licenseURL", "attribution", "byteCount", "sha256")
BOUND_KEYS = ("west", "south", "east", "north")
ATTRIBUTION = "© OpenStreetMap contributors"
LICENSE = "ODbL-1.0"
LICENSE_URL = "https://www.openstreetmap.org/copyright"
ROUTING_COMPATIBILITY = {
    "engineVersion": "3.9.2",
    "engineCommit": "a919bb6b64d61d12f79ea5466d5cf599a39714ad",
    "timeZoneDataVersion": "2025b",
}


def sha256(stream):
    checksum = hashlib.sha256()
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        checksum.update(chunk)
    return checksum.hexdigest()


def digest(path):
    with path.open("rb") as stream:
        return sha256(stream)


def valid_https(value):
    if not isinstance(value, str) or any(ch.isspace() for ch in value):
        return False
    url = urlsplit(value)
    return url.scheme == "https" and url.hostname and url.username is None and not url.fragment


def validate_metadata(metadata):
    if not isinstance(metadata["region"], str) or not metadata["region"].strip() or len(metadata["region"]) > 120:
        raise ValueError("Expected a nonempty region name of at most 120 characters.")
    if not isinstance(metadata["dataVersion"], str) or not metadata["dataVersion"].strip():
        raise ValueError("Provide an extract date or stable dataset revision.")
    if not valid_https(metadata["source"]) or not valid_https(metadata["artifactBaseURL"]):
        raise ValueError("Provide HTTPS source and artifact URLs without credentials or fragments.")
    if urlsplit(metadata["artifactBaseURL"]).query:
        raise ValueError("The artifact base URL must be a directory URL without a query string.")
    if not re.fullmatch(r"[0-9a-f]{64}", metadata["sourceSHA256"]):
        raise ValueError("Expected a lowercase SHA-256 for the source extract.")
    bounds = metadata["bounds"]
    if (not isinstance(bounds, dict) or set(bounds) != set(BOUND_KEYS)
            or any(type(value) not in (int, float) for value in bounds.values())):
        raise ValueError("Expected four numeric bounds.")
    west, south, east, north = (bounds[key] for key in BOUND_KEYS)
    if not (-180 <= west <= 180 and -180 <= east <= 180 and west != east and (west, east) != (180, -180)
            and -90 <= south < north <= 90):
        raise ValueError("Bounds must describe a nonempty longitude and latitude range.")


def validate_places(path, metadata):
    with closing(sqlite3.connect(f"{path.resolve().as_uri()}?mode=ro&immutable=1", uri=True)) as db:
        if db.execute("PRAGMA application_id").fetchone()[0] != 0x54464B50:
            raise ValueError("Expected a Tinfoil Kit place index.")
        if db.execute("PRAGMA user_version").fetchone()[0] != 1:
            raise ValueError("Unsupported place index version.")
        if db.execute("PRAGMA quick_check").fetchall() != [("ok",)]:
            raise ValueError("The place index did not pass SQLite integrity checks.")
        actual = dict(db.execute("SELECT key, value FROM metadata"))
        count = db.execute("SELECT count(*) FROM places").fetchone()[0]
        if not count or actual.get("placeCount") != str(count):
            raise ValueError("The place count does not match the index.")
        db.execute("""
            SELECT p.id, p.title, p.category, p.category_words, p.address, p.latitude, p.longitude
            FROM place_search JOIN places AS p ON p.id = place_search.rowid
            WHERE place_search MATCH 'TinfoilKitIndexCheck'
            ORDER BY bm25(place_search, 4.0, 3.0, 1.0) LIMIT 1
        """).fetchall()
        db.execute("""
            SELECT b.min_latitude, b.max_latitude, b.min_longitude, b.max_longitude
            FROM place_bounds AS b JOIN places AS p ON p.id = b.id LIMIT 1
        """).fetchall()
    bounds = tuple(float(value) for value in actual["bounds"].split(","))
    if bounds != tuple(metadata["bounds"][key] for key in BOUND_KEYS):
        raise ValueError("The place index bounds do not match the bundle.")
    return actual


def validate_routing(path, metadata):
    with path.open("rb") as stream:
        header = stream.read(12)
        if len(header) != 12:
            raise ValueError("Incomplete routing pack header.")
        magic, length = struct.unpack("<8sI", header)
        if magic != b"TFKROUTE" or not 1 <= length <= 65_536:
            raise ValueError("Invalid routing pack header.")
        manifest_bytes = stream.read(length)
        if len(manifest_bytes) != length:
            raise ValueError("Incomplete routing manifest.")
        actual = json.loads(manifest_bytes)
        graph_bytes = path.stat().st_size - stream.tell()
        if actual["schemaVersion"] != 1 or any(actual[key] != value for key, value in ROUTING_COMPATIBILITY.items()):
            raise ValueError("The routing pack is incompatible with the app's routing engine.")
        if (graph_bytes <= 1024 or graph_bytes % 512 or graph_bytes != actual["graphByteCount"]
                or sha256(stream) != actual["graphSHA256"]):
            raise ValueError("The routing graph does not match its manifest.")
    for key in ("bounds", "sourceSHA256"):
        if actual[key] != metadata[key]:
            raise ValueError(f"Routing pack {key} does not match the bundle.")
    return actual


def pmtiles_bounds(path, byte_count):
    # PMTiles v3 uses little-endian offsets and signed E7 coordinates in its 127-byte header.
    with path.open("rb") as stream:
        header = stream.read(127)
    if (len(header) != 127 or header[:8] != b"PMTiles\x03" or header[99] != 1
            or not header[100] <= header[101] <= 30):
        raise ValueError("Expected a PMTiles v3 Mapbox Vector Tile basemap.")
    root, metadata, leaves, tiles = struct.iter_unpack("<QQ", header[8:72])
    if not root[1] or sum(root) > 16_384 or not tiles[1]:
        raise ValueError("The PMTiles basemap needs a root directory and tile data.")
    previous_end = 127
    for offset, length in sorted(section for section in (root, metadata, leaves, tiles) if section[1]):
        if offset < previous_end or offset + length > byte_count:
            raise ValueError("A PMTiles basemap section overlaps or exceeds the archive.")
        previous_end = offset + length
    west, south, east, north = (value / 10_000_000 for value in struct.unpack_from("<iiii", header, 102))
    if not (-180 <= west < east <= 180 and -90 <= south < north <= 90):
        raise ValueError("The PMTiles basemap bounds are invalid.")
    return dict(zip(BOUND_KEYS, (west, south, east, north)))


def basemap_asset(path, declared, bundle):
    entry = {key: declared[key] for key in BASEMAP_FIELDS}
    if any(not isinstance(entry[key], str) or not entry[key].strip()
           for key in ("dataVersion", "license", "attribution")):
        raise ValueError("Provide the basemap edition, license identifier and attribution.")
    if not all(valid_https(entry[key]) for key in ("source", "licenseURL")):
        raise ValueError("Provide HTTPS basemap source and license URLs without credentials or fragments.")
    if type(entry["byteCount"]) is not int or entry["byteCount"] <= 127:
        raise ValueError("Provide the exact basemap byte count.")
    if not isinstance(entry["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", entry["sha256"]):
        raise ValueError("Provide a lowercase SHA-256 for the basemap.")
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"Expected {BASEMAP_NAME} to be a regular file.")
    if path.stat().st_size != entry["byteCount"]:
        raise ValueError("The basemap does not match the declared byte count.")
    if digest(path) != entry["sha256"]:
        raise ValueError("The basemap does not match the pinned SHA-256.")

    coverage = pmtiles_bounds(path, entry["byteCount"])
    region = bundle["bounds"]
    west, south, east, north = (region[key] for key in BOUND_KEYS)
    if west > east:
        west, east = -180, 180
    if not (coverage["west"] <= west and coverage["east"] >= east
            and coverage["south"] <= south and coverage["north"] >= north):
        raise ValueError("The PMTiles basemap bounds do not cover the full bundle region.")
    return dict(entry, filename=BASEMAP_NAME, bounds=coverage,
                url=bundle["artifactBaseURL"].rstrip("/") + "/" + BASEMAP_NAME)


def bundle_manifest(directory, metadata, basemap=None):
    validate_metadata(metadata)
    shared = dict(metadata, attribution=ATTRIBUTION, license=LICENSE, licenseURL=LICENSE_URL)
    assets = {}
    for kind, validate in (("places", validate_places), ("routing", validate_routing)):
        name = ASSETS[kind]
        path = directory / name
        if path.is_symlink() or not path.is_file():
            raise ValueError(f"Expected {name} to be a regular file.")
        actual = validate(path, shared)
        for key in ("region", "dataVersion", "source", "attribution", "license", "licenseURL"):
            if actual[key] != shared[key]:
                raise ValueError(f"{name} has mismatched {key}.")
        assets[kind] = {
            "filename": name,
            "url": shared["artifactBaseURL"].rstrip("/") + "/" + name,
            "byteCount": path.stat().st_size,
            "sha256": digest(path),
        }
    if basemap is not None:
        assets["basemap"] = basemap
    return dict(shared, schemaVersion=2 if basemap is not None else 1, assets=assets)


def build(args):
    metadata = {
        "region": args.region, "dataVersion": args.data_version,
        "source": args.source, "sourceSHA256": args.source_sha256,
        "bounds": dict(zip(BOUND_KEYS, args.bounds)), "artifactBaseURL": args.artifact_base_url,
    }
    validate_metadata(metadata)
    basemap_fields = {
        "dataVersion": args.basemap_edition, "source": args.basemap_source,
        "license": args.basemap_license, "licenseURL": args.basemap_license_url,
        "attribution": args.basemap_attribution, "byteCount": args.basemap_byte_count, "sha256": args.basemap_sha256,
    }
    if args.basemap is None and any(value is not None for value in basemap_fields.values()):
        raise ValueError("Provide --basemap when supplying basemap metadata.")
    if args.basemap is not None and (
            args.basemap.suffix.lower() != ".pmtiles" or any(value is None for value in basemap_fields.values())):
        raise ValueError("Provide a .pmtiles file and all basemap metadata options.")
    output = args.directory.absolute()
    if output.exists() or output.is_symlink():
        raise ValueError("Choose a new output directory for this bundle edition.")
    if not args.pbf.name.lower().endswith(".osm.pbf"):
        raise ValueError("Choose an .osm.pbf extract.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".regional-bundle-", dir=output.parent) as temporary:
        work = Path(temporary)
        source = work / "region.osm.pbf"
        shutil.copyfile(args.pbf, source)
        if digest(source) != args.source_sha256:
            raise ValueError("The source extract does not match the pinned SHA-256.")
        artifacts = work / "artifacts"
        artifacts.mkdir()
        basemap = None
        if args.basemap is not None:
            basemap_path = artifacts / BASEMAP_NAME
            shutil.copyfile(args.basemap, basemap_path)
            basemap = basemap_asset(basemap_path, basemap_fields, metadata)
        common = [
            "--region", args.region, "--data-version", args.data_version, "--source", args.source,
            "--bounds", *(str(value) for value in args.bounds),
        ]
        subprocess.run([
            sys.executable, SCRIPTS / "build-regional-place-index.py", source, artifacts / ASSETS["places"], *common,
        ], check=True)
        routing_options = ["--architecture", args.architecture] if args.architecture else []
        subprocess.run([
            sys.executable, SCRIPTS / "build-regional-routing-pack.py", source, artifacts / ASSETS["routing"],
            *common, *routing_options,
        ], check=True)
        manifest = bundle_manifest(artifacts, metadata, basemap)
        (artifacts / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8",
        )
        os.rename(artifacts, output)
    print(f"Wrote regional bundle to {output}.")


def verify(directory):
    actual = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    metadata = {key: actual[key] for key in ("region", "dataVersion", "source", "sourceSHA256", "bounds",
                                             "artifactBaseURL")}
    validate_metadata(metadata)
    basemap = None
    if actual["schemaVersion"] == 2:
        basemap = basemap_asset(directory / BASEMAP_NAME, actual["assets"]["basemap"], metadata)
    elif actual["schemaVersion"] != 1:
        raise ValueError("Unsupported regional bundle manifest version.")
    if bundle_manifest(directory, metadata, basemap) != actual:
        raise ValueError("The catalog manifest does not match the regional artifacts.")
    print(f"Verified {directory / 'manifest.json'} and all artifacts.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    builder = commands.add_parser("build")
    builder.add_argument("pbf", type=Path)
    builder.add_argument("directory", type=Path, help="New directory for artifacts and the catalog manifest")
    builder.add_argument("--region", required=True)
    builder.add_argument("--data-version", required=True)
    builder.add_argument("--source", required=True, help="HTTPS URL where the publisher identifies the extract")
    builder.add_argument("--source-sha256", required=True, help="Pinned SHA-256 of the OSM PBF")
    builder.add_argument("--artifact-base-url", required=True, help="HTTPS directory URL where artifacts will be hosted")
    builder.add_argument("--bounds", nargs=4, type=float, required=True, metavar=("WEST", "SOUTH", "EAST", "NORTH"))
    builder.add_argument("--architecture", choices=("amd64", "arm64"))
    basemap = builder.add_argument_group("optional basemap and its required publisher metadata")
    basemap.add_argument("--basemap", type=Path, help="Locally available PMTiles v3 MVT archive")
    basemap.add_argument("--basemap-edition", help="Publisher's date or stable revision for this map")
    basemap.add_argument("--basemap-source", help="HTTPS source for this basemap edition")
    basemap.add_argument("--basemap-license", help="Identifier for this basemap's license")
    basemap.add_argument("--basemap-license-url", help="HTTPS URL for this basemap's license terms")
    basemap.add_argument("--basemap-attribution", help="Publisher's required attribution")
    basemap.add_argument("--basemap-byte-count", type=int, help="Pinned byte count for the PMTiles file")
    basemap.add_argument("--basemap-sha256", help="Pinned SHA-256 for the PMTiles file")
    verifier = commands.add_parser("verify")
    verifier.add_argument("directory", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "build":
            build(args)
        else:
            verify(args.directory)
    except (OSError, KeyError, TypeError, ValueError, sqlite3.Error, subprocess.CalledProcessError) as error:
        print(f"Regional bundle {args.command} failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
