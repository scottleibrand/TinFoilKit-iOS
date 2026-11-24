"""Build regional bundles from synthetic inputs and test local verification."""

import hashlib
import json
from pathlib import Path
import sqlite3
import struct
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET

import osmium


ROOT = Path(__file__).resolve().parents[2]
NETWORK = ROOT / "Scripts/routing/fixture.osm"
NETWORK_SHA256 = "7e2aa13cf0845741626d9dae75d48858653c36f0bc4ac1e3e1436c5aa26f8eab"
TOOL = [sys.executable, ROOT / "Scripts/build-regional-bundle.py"]


def expect_failure(args, message):
    result = subprocess.run(args, text=True, capture_output=True)
    assert result.returncode == 1 and message in result.stderr, result


def write_basemap(path):
    """Write a PMTiles v3 archive with one uncompressed z0 vector tile."""
    tile = b"\x1a\x17\x0a\x07fixture\x12\x07\x18\x01\x22\x03\x09\x00\x00\x28\x80\x20\x78\x02"
    # One directory entry for tile ID 0, run length 1, and encoded offset 1 (byte offset 0).
    root = bytes([1, 0, 1, len(tile), 1])
    metadata = b"{}"
    metadata_offset = 127 + len(root)
    tile_offset = metadata_offset + len(metadata)
    header = bytearray(127)
    header[:8] = b"PMTiles\x03"
    struct.pack_into("<11Q", header, 8, 127, len(root), metadata_offset, len(metadata),
                     tile_offset, 0, tile_offset, len(tile), 1, 1, 1)
    header[96:102] = bytes([1, 1, 1, 1, 0, 0])
    struct.pack_into("<4i", header, 102, -1_220_060_000, 474_950_000, -1_219_980_000, 475_050_000)
    struct.pack_into("<Bii", header, 118, 0, -1_220_020_000, 475_000_000)
    path.write_bytes(header + root + metadata + tile)


def check_basemap(work, pbf, options, metadata):
    source = work / "source.pmtiles"
    write_basemap(source)
    payload = source.read_bytes()
    digest = hashlib.sha256(payload).hexdigest()
    output = work / "bundle-with-basemap"
    command = [
        *TOOL, "build", pbf, output, *options, "--basemap", source, "--basemap-edition", metadata["dataVersion"],
        "--basemap-source", metadata["source"], "--basemap-license", metadata["license"],
        "--basemap-license-url", metadata["licenseURL"], "--basemap-attribution", metadata["attribution"],
    ]
    expect_failure(command, "all basemap metadata options")
    expect_failure([*command, "--basemap-byte-count", str(len(payload) + 1), "--basemap-sha256", digest],
                   "does not match the declared byte count")
    expect_failure([*command, "--basemap-byte-count", str(len(payload)), "--basemap-sha256", "0" * 64],
                   "does not match the pinned SHA-256")
    command += ["--basemap-byte-count", str(len(payload)), "--basemap-sha256", digest]
    expect_failure([*command, "--bounds", "-123", "47.496", "-121.999", "47.504"], "do not cover the full")
    assert not output.exists()
    subprocess.run(command, check=True)
    verify = [*TOOL, "verify", output]
    subprocess.run(verify, check=True)
    path = output / "manifest.json"
    original = path.read_text(encoding="utf-8")
    manifest = json.loads(original)
    assert manifest["schemaVersion"] == 2
    assert manifest["assets"]["basemap"] == dict(
        metadata, filename="basemap.pmtiles", url="https://example.invalid/bundles/fixture-v1/basemap.pmtiles",
        bounds={"west": -122.006, "south": 47.495, "east": -121.998, "north": 47.505},
        byteCount=len(payload), sha256=digest,
    )
    basemap = output / "basemap.pmtiles"
    assert basemap.read_bytes() == payload
    basemap.write_bytes(payload[:-1])
    expect_failure(verify, "does not match the declared byte count")
    basemap.write_bytes(payload[:-1] + b"\xff")
    expect_failure(verify, "does not match the pinned SHA-256")

    broken = bytearray(payload)
    struct.pack_into("<Q", broken, 56, len(payload))
    basemap.write_bytes(broken)
    manifest["assets"]["basemap"]["sha256"] = hashlib.sha256(broken).hexdigest()
    path.write_text(json.dumps(manifest), encoding="utf-8")
    expect_failure(verify, "section overlaps or exceeds the archive")

    basemap.write_bytes(payload)
    manifest = json.loads(original)
    manifest["assets"]["basemap"]["bounds"]["west"] = -123.0
    path.write_text(json.dumps(manifest), encoding="utf-8")
    expect_failure(verify, "catalog manifest does not match")


def main():
    assert hashlib.sha256(NETWORK.read_bytes()).hexdigest() == NETWORK_SHA256
    build_path = ROOT / ".build"
    build_path.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="bundle-fixture-", dir=build_path) as temporary:
        work = Path(temporary)
        osm = work / "regional-fixture.osm"
        network = ET.parse(NETWORK)
        place = network.find("./node[@id='2']")
        for key, value in (("amenity", "pharmacy"), ("name", "Fixture Pharmacy"),
                           ("addr:housenumber", "10"), ("addr:street", "East Main")):
            ET.SubElement(place, "tag", {"k": key, "v": value})
        network.write(osm, encoding="utf-8")
        pbf = work / "regional-fixture.osm.pbf"
        with osmium.SimpleWriter(pbf) as writer:
            for item in osmium.FileProcessor(osm):
                writer.add(item)

        output = work / "bundle"
        options = [
            "--region", "Synthetic region", "--data-version", "fixture-v1",
            "--source", "https://example.invalid/region.osm.pbf", "--artifact-base-url",
            "https://example.invalid/bundles/fixture-v1/", "--bounds", "-122.005", "47.496", "-121.999", "47.504",
        ]
        build = [*TOOL, "build", pbf, output]
        expect_failure([*build, *options, "--source-sha256", "0" * 64], "does not match the pinned SHA-256")
        assert not output.exists()
        source_digest = hashlib.sha256(pbf.read_bytes()).hexdigest()
        options += ["--source-sha256", source_digest]
        subprocess.run([*build, *options], check=True)
        subprocess.run([*TOOL, "verify", output], check=True)

        with sqlite3.connect(output / "places.sqlite") as db:
            assert db.execute("SELECT category, address FROM places WHERE title = ?", ("Fixture Pharmacy",)
                              ).fetchone() == ("pharmacy", "10 East Main")

        manifest_path = output / "manifest.json"
        original = manifest_path.read_text(encoding="utf-8")
        manifest = json.loads(original)
        assert manifest["schemaVersion"] == 1 and set(manifest["assets"]) == {"places", "routing"}
        assert manifest["sourceSHA256"] == source_digest
        for asset in manifest["assets"].values():
            payload = (output / asset["filename"]).read_bytes()
            assert asset["sha256"] == hashlib.sha256(payload).hexdigest()
            assert asset["byteCount"] == len(payload)

        manifest["assets"]["places"]["sha256"] = "0" * 64
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
        expect_failure([*TOOL, "verify", output], "catalog manifest does not match")
        manifest_path.write_text(original, encoding="utf-8")
        route_path = output / "routing.tfkroute"
        with route_path.open("r+b") as pack:
            pack.seek(-1, 2)
            last_byte = pack.read(1)
            pack.seek(-1, 2)
            pack.write(bytes([last_byte[0] ^ 1]))
        expect_failure([*TOOL, "verify", output], "routing graph does not match")
        with route_path.open("r+b") as pack:
            pack.seek(-1, 2)
            pack.write(last_byte)
            pack.seek(8)
            length, = struct.unpack("<I", pack.read(4))
            data = pack.read(length)
            incompatible = data.replace(b'"3.9.2"', b'"0.0.0"')
            assert incompatible != data
            pack.seek(12)
            pack.write(incompatible)
        expect_failure([*TOOL, "verify", output], "incompatible with the app")
        with route_path.open("r+b") as pack:
            pack.seek(12)
            pack.write(data)
        place_path = output / "places.sqlite"
        original_place_path = place_path.rename(work / "original.sqlite")
        place_path.symlink_to(original_place_path)
        expect_failure([*TOOL, "verify", output], "places.sqlite to be a regular file")
        place_path.unlink()
        original_place_path.rename(place_path)
        with sqlite3.connect(place_path) as db:
            db.execute("DROP TABLE place_search")
        expect_failure([*TOOL, "verify", output], "no such table: place_search")

        check_basemap(work, pbf, options, {
            "dataVersion": "map-fixture-v2", "source": "https://example.invalid/synthetic-basemap.pmtiles",
            "license": "MIT", "licenseURL": "https://opensource.org/license/mit",
            "attribution": "Tinfoil Kit synthetic basemap fixture",
        })
    print("Regional bundle fixture passed.")


if __name__ == "__main__":
    main()
