#!/usr/bin/env python3
"""Build or verify regional place and routing artifacts with a catalog manifest."""

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
BOUND_KEYS = ("west", "south", "east", "north")
ATTRIBUTION = "© OpenStreetMap contributors"
LICENSE = "ODbL-1.0"
LICENSE_URL = "https://www.openstreetmap.org/copyright"


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
        if (actual["schemaVersion"] != 1 or graph_bytes <= 0 or graph_bytes != actual["graphByteCount"]
                or sha256(stream) != actual["graphSHA256"]):
            raise ValueError("The routing graph does not match its manifest.")
    for key in ("bounds", "sourceSHA256"):
        if actual[key] != metadata[key]:
            raise ValueError(f"Routing pack {key} does not match the bundle.")
    return actual


def bundle_manifest(directory, metadata):
    validate_metadata(metadata)
    shared = dict(metadata, attribution=ATTRIBUTION, license=LICENSE, licenseURL=LICENSE_URL)
    assets = {}
    for kind, validate in (("places", validate_places), ("routing", validate_routing)):
        name = ASSETS[kind]
        path = directory / name
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
    return dict(shared, schemaVersion=1, assets=assets)


def build(args):
    metadata = {
        "region": args.region, "dataVersion": args.data_version,
        "source": args.source, "sourceSHA256": args.source_sha256,
        "bounds": dict(zip(BOUND_KEYS, args.bounds)), "artifactBaseURL": args.artifact_base_url,
    }
    validate_metadata(metadata)
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
        manifest = bundle_manifest(artifacts, metadata)
        (artifacts / "manifest.json").write_text(
            json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8",
        )
        os.rename(artifacts, output)
    print(f"Wrote regional bundle to {output}.")


def verify(directory):
    actual = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    metadata = {key: actual[key] for key in ("region", "dataVersion", "source", "sourceSHA256", "bounds",
                                             "artifactBaseURL")}
    if bundle_manifest(directory, metadata) != actual:
        raise ValueError("The catalog manifest does not match the regional artifacts.")
    print(f"Verified {directory / 'manifest.json'} and both artifacts.")


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
