"""Build a bundle from the repository's synthetic network and test local verification."""

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
from verify_download import verify_download


ROOT = Path(__file__).resolve().parents[2]
NETWORK = ROOT / "Scripts/routing/fixture.osm"
NETWORK_SHA256 = "7e2aa13cf0845741626d9dae75d48858653c36f0bc4ac1e3e1436c5aa26f8eab"
TOOL = [sys.executable, ROOT / "Scripts/build-regional-bundle.py"]


def expect_failure(args, message):
    result = subprocess.run(args, text=True, capture_output=True)
    assert result.returncode == 1 and message in result.stderr, result


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
        build = [
            *TOOL, "build", pbf, output, "--region", "Synthetic region", "--data-version", "fixture-v1",
            "--source", "https://example.invalid/region.osm.pbf", "--artifact-base-url",
            "https://example.invalid/bundles/fixture-v1/", "--bounds", "-122.005", "47.496", "-121.999", "47.504",
        ]
        expect_failure([*build, "--source-sha256", "0" * 64], "does not match the pinned SHA-256")
        assert not output.exists()
        source_digest = hashlib.sha256(pbf.read_bytes()).hexdigest()
        subprocess.run([*build, "--source-sha256", source_digest], check=True)
        subprocess.run([*TOOL, "verify", output], check=True)
        verify_download(output, work / "downloaded-bundle")

        with sqlite3.connect(output / "places.sqlite") as db:
            assert db.execute("SELECT category, address FROM places WHERE title = ?", ("Fixture Pharmacy",)
                              ).fetchone() == ("pharmacy", "10 East Main")

        manifest_path = output / "manifest.json"
        original = manifest_path.read_text(encoding="utf-8")
        manifest = json.loads(original)
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
    print("Regional bundle fixture passed.")


if __name__ == "__main__":
    main()
