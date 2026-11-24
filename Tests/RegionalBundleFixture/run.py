"""Build a bundle from the repository's synthetic network and test local verification."""

import hashlib
import json
from pathlib import Path
import sqlite3
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
        with (output / "routing.tfkroute").open("r+b") as pack:
            pack.seek(-1, 2)
            last_byte = pack.read(1)
            pack.seek(-1, 2)
            pack.write(bytes([last_byte[0] ^ 1]))
        expect_failure([*TOOL, "verify", output], "routing graph does not match")
    print("Regional bundle fixture passed.")


if __name__ == "__main__":
    main()
