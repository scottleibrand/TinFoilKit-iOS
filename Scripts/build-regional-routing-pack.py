#!/usr/bin/env python3
"""Build an offline Tinfoil Kit routing pack from a regional OpenStreetMap PBF."""

import argparse
import hashlib
import json
import os
import platform
import re
import shutil
import struct
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path
from urllib.parse import urlsplit


ENGINE = "3.9.2"
ENGINE_COMMIT = "a919bb6b64d61d12f79ea5466d5cf599a39714ad"
TIMEZONE_DATA = "2025b"
# Official images of the engine commit in RoutingPack. Pin each architecture independently.
IMAGE_DIGESTS = {
    "arm64": "5a82df3bb7273f6472c57b72748e255c9193215f0d7cdcb244c12521278baf2b",
    "amd64": "f56602e1331de71c6191c9e19cf9c5d89f5dc7437b77361700146c4dd1829516",
}
IMAGE_REPOSITORY = "ghcr.io/valhalla/valhalla"
TILE_INDEX_RECORD = struct.Struct("<QII")
TILE_PATH = re.compile(r"([012])/(\d{3}(?:/\d{3})+)\.gph\Z", re.ASCII)
CHUNK_SIZE = 1024 * 1024


def copy_and_hash(source: Path, destination) -> tuple[int, str]:
    digest = hashlib.sha256()
    byte_count = 0
    with source.open("rb") as stream:
        for data in iter(lambda: stream.read(CHUNK_SIZE), b""):
            destination.write(data)
            digest.update(data)
            byte_count += len(data)
    return byte_count, digest.hexdigest()


def validate_graph(graph: Path) -> int:
    """Validate the output of the pinned upstream tile-extract tool."""
    if graph.stat().st_size <= 1024 or graph.stat().st_size % 512:
        raise ValueError("Expected an uncompressed Valhalla tile archive.")
    with tarfile.open(graph, mode="r:") as archive:
        index = archive.next()
        if index is None or index.name != "index.bin" or not index.isfile() or not index.size:
            raise ValueError("The graph is missing its Valhalla tile index.")
        if index.size % TILE_INDEX_RECORD.size or index.size >= graph.stat().st_size:
            raise ValueError("The Valhalla tile index has an invalid length.")
        with archive.extractfile(index) as stream:
            graph_ids = set()
            tile = archive.next()
            while tile is not None:
                match = TILE_PATH.fullmatch(tile.name)
                if not match or not tile.isfile() or not tile.size:
                    raise ValueError(f"Unexpected member in the Valhalla tile archive: {tile.name}")
                record = stream.read(TILE_INDEX_RECORD.size)
                if len(record) != TILE_INDEX_RECORD.size:
                    raise ValueError("A graph tile is missing from the Valhalla tile index.")
                offset, graph_id, size = TILE_INDEX_RECORD.unpack(record)
                tile_id = (int(match[2].replace("/", "")) << 3) | int(match[1])
                if graph_id != tile_id or graph_id in graph_ids or offset != tile.offset_data or size != tile.size:
                    raise ValueError(f"The Valhalla index does not match tile {tile.name}.")
                graph_ids.add(graph_id)
                tile = archive.next()
            if not graph_ids or stream.read(1):
                raise ValueError("The Valhalla tile index does not match the archive.")
    return len(graph_ids)


def build_graph(work: Path, architecture: str, concurrency: int, *, admin: bool, timezone: bool) -> Path:
    image = f"{IMAGE_REPOSITORY}@sha256:{IMAGE_DIGESTS[architecture]}"
    if ":" in str(work):
        raise ValueError("Choose an output path without a colon so Docker can mount the work directory.")
    command = [
        "docker", "run", "--rm", "--network", "none", "--platform", f"linux/{architecture}",
        "--user", f"{os.getuid()}:{os.getgid()}", "--volume", f"{work}:/work:rw", "--workdir", "/work",
    ]

    def run(binary: str, *args: str, capture: bool = False) -> str:
        result = subprocess.run(
            [*command, "--entrypoint", binary, image, *args],
            check=True, text=True, stdout=subprocess.PIPE if capture else None,
        )
        return result.stdout if capture else ""

    built_revision = run("/bin/cat", "/usr/local/valhalla_version", capture=True).strip()
    version = run("valhalla_build_tiles", "--version", capture=True).strip()
    # Upstream only embeds the short SHA in master builds. Release images use the
    # checked-out release tag and leave the marker empty, so the digest pins those.
    if (built_revision and built_revision != ENGINE_COMMIT[:7]) or version != ENGINE:
        raise ValueError(f"Valhalla builder version mismatch ({built_revision}, {version}).")
    print(f"Using pinned Valhalla {ENGINE} release image.", flush=True)
    config = json.loads(run("valhalla_build_config", capture=True))
    config["mjolnir"].update(
        tile_dir="/work/tiles", tile_extract="", tile_url="", traffic_extract="",
        concurrency=concurrency, admin="/work/admin.sqlite" if admin else "",
        timezone="/work/timezone.sqlite" if timezone else "",
    )
    config["mjolnir"]["data_processing"]["use_admin_db"] = admin
    configuration = work / "config.json"
    configuration.write_text(json.dumps(config), encoding="utf-8")
    (work / "tiles").mkdir()
    run("valhalla_build_tiles", "-c", "/work/config.json", "/work/region.osm.pbf")
    config["mjolnir"]["tile_extract"] = "/work/tiles.tar"
    configuration.write_text(json.dumps(config), encoding="utf-8")
    run("valhalla_build_extract", "-c", "/work/config.json")
    return work / "tiles.tar"


def write_pack(graph: Path, output: Path, metadata: dict) -> None:
    with output.open("wb") as pack:
        # Space for the known-width SHA-256 is included before streaming the graph.
        # This lets the final manifest and graph checksum describe the exact same bytes.
        manifest = dict(metadata, graphByteCount=graph.stat().st_size, graphSHA256="0" * 64)
        encode = lambda value: json.dumps(value, ensure_ascii=False, sort_keys=True).encode("utf-8")
        placeholder = encode(manifest)
        if not 1 <= len(placeholder) <= 65_536:
            raise ValueError("The metadata is too large for a routing pack.")
        pack.write(struct.pack("<8sI", b"TFKROUTE", len(placeholder)))
        offset = pack.tell()
        pack.write(placeholder)
        count, digest = copy_and_hash(graph, pack)
        if count != manifest["graphByteCount"]:
            raise ValueError("The graph changed while packaging.")
        manifest["graphSHA256"] = digest
        pack.seek(offset)
        pack.write(encode(manifest))
        pack.flush()
        os.fsync(pack.fileno())


def parse_arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("pbf", type=Path, help="Local regional OpenStreetMap extract (.osm.pbf)")
    parser.add_argument("output", type=Path, help="Destination .tfkroute file")
    parser.add_argument("--region", required=True, help="Region name as displayed on iOS")
    parser.add_argument("--bounds", required=True, nargs=4, type=float, metavar=("WEST", "SOUTH", "EAST", "NORTH"),
                        help="Extent covered by the extract in decimal degrees")
    parser.add_argument("--source", required=True, help="HTTPS URL of the OpenStreetMap extract")
    parser.add_argument("--data-version", required=True, help="Extract date or stable dataset revision")
    default_arch = {"arm64": "arm64", "aarch64": "arm64", "x86_64": "amd64", "AMD64": "amd64"}
    parser.add_argument("--architecture", choices=IMAGE_DIGESTS, default=default_arch.get(platform.machine(), "arm64"))
    parser.add_argument("--workers", type=int, default=min(4, os.cpu_count() or 1))
    parser.add_argument("--admin-database", type=Path, help="Optional Valhalla administrative boundaries database")
    parser.add_argument("--timezone-database", type=Path, help="Optional Valhalla spatial timezone database")
    parser.add_argument("--replace", action="store_true", help="Replace an existing output after a successful build")
    args = parser.parse_args()

    west, south, east, north = args.bounds
    uri = urlsplit(args.source)
    if (uri.scheme != "https" or not uri.hostname or uri.username is not None
            or any(ch.isspace() for ch in args.source)):
        parser.error("--source must be an HTTPS URL without credentials.")
    if not -180 <= west <= 180 or not -180 <= east <= 180 or west == east or (west, east) == (180, -180):
        parser.error("--bounds west and east must describe a nonempty longitude range.")
    if not -90 <= south < north <= 90:
        parser.error("--bounds south and north must describe a nonempty latitude range.")
    if not args.region.strip() or len(args.region) > 120 or not args.data_version.strip():
        parser.error("Provide a nonempty region of at most 120 characters and a data version.")
    if not 1 <= args.workers <= 64:
        parser.error("--workers must be between 1 and 64.")
    if not args.pbf.is_file() or not args.pbf.name.lower().endswith(".osm.pbf"):
        parser.error("Choose an existing .osm.pbf extract.")
    if args.output.suffix.lower() != ".tfkroute":
        parser.error("The output filename must end in .tfkroute.")
    if args.output.exists() and not args.replace:
        parser.error("The output already exists. Choose a different name or pass --replace.")
    for database in (args.admin_database, args.timezone_database):
        if database is not None and not database.is_file():
            parser.error(f"Database does not exist: {database}")
    return args


def main() -> int:
    args = parse_arguments()
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    try:
        with tempfile.TemporaryDirectory(prefix=".route-build-", dir=output.parent) as work_dir:
            work = Path(work_dir)
            with (work / "region.osm.pbf").open("wb") as destination:
                _, source_digest = copy_and_hash(args.pbf, destination)
            if args.admin_database:
                shutil.copyfile(args.admin_database, work / "admin.sqlite")
            if args.timezone_database:
                shutil.copyfile(args.timezone_database, work / "timezone.sqlite")
            graph = build_graph(work, args.architecture, args.workers,
                                admin=args.admin_database is not None, timezone=args.timezone_database is not None)
            tile_count = validate_graph(graph)
            pack = work / "region.tfkroute"
            write_pack(graph, pack, {
                "schemaVersion": 1,
                "region": args.region,
                "dataVersion": args.data_version,
                "engineVersion": ENGINE,
                "engineCommit": ENGINE_COMMIT,
                "timeZoneDataVersion": TIMEZONE_DATA,
                "bounds": dict(zip(("west", "south", "east", "north"), args.bounds)),
                "source": args.source,
                "sourceSHA256": source_digest,
                "attribution": "© OpenStreetMap contributors",
                "license": "ODbL-1.0",
                "licenseURL": "https://www.openstreetmap.org/copyright",
            })
            if args.replace:
                os.replace(pack, output)
            else:
                os.link(pack, output)
            print(f"Wrote {output} with {tile_count:,} tiles ({output.stat().st_size:,} bytes).")
    except (OSError, ValueError, subprocess.CalledProcessError, tarfile.TarError) as error:
        print(f"Routing pack build failed: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
