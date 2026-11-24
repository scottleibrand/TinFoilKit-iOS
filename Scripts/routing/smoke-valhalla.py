#!/usr/bin/env python3
"""Build a synthetic offline Valhalla graph and exercise its actual routing rules."""

import argparse
import json
from pathlib import Path
import subprocess
import sys

import osmium
import valhalla

WEST = {"lat": 47.50003, "lon": -122.0035, "search_cutoff": 29}
EAST = {"lat": 47.50002, "lon": -122.0004, "search_cutoff": 29}
SOUTH = {"lat": 47.4978, "lon": -122.00203, "search_cutoff": 29}


def build_fixture(output: Path) -> Path:
    fixture = Path(__file__).with_name("fixture.osm")
    pbf = output / "fixture.osm.pbf"
    with osmium.SimpleWriter(pbf, overwrite=True) as writer:
        for feature in osmium.FileProcessor(fixture):
            writer.add(feature)

    tiles = output / "tiles"
    if tiles.exists():
        raise FileExistsError(f"Choose a fresh output path. Fixture tiles already exist at {tiles}")
    tiles.mkdir()
    config = valhalla.get_config(tile_extract="", tile_dir=tiles)
    config["mjolnir"]["traffic_extract"] = ""
    config["mjolnir"]["concurrency"] = 2
    config_file = output / "valhalla.json"
    config_file.write_text(json.dumps(config, indent=2), encoding="utf-8")
    # Use the tool shipped in the pinned wheel. Its console entry point searches PATH.
    tool = valhalla.PYVALHALLA_DIR / "bin" / "valhalla_build_tiles"
    with (output / "build.log").open("wb") as log:
        subprocess.run([tool, "-c", config_file, pbf], check=True, stdout=log, stderr=log)
    return config_file


def route_request(costing: str, start: dict, end: dict) -> dict:
    return {"locations": [start, end], "costing": costing, "units": "kilometers"}


def start_at(shape: str) -> tuple[float, float]:
    """Decode the first coordinate of Valhalla's six-decimal encoded polyline."""
    chars = iter(shape)
    values = []
    for _ in range(2):
        value = shift = 0
        for char in chars:
            chunk = ord(char) - 63
            value |= (chunk & 31) << shift
            shift += 5
            if chunk < 32:
                values.append((~(value >> 1) if value & 1 else value >> 1) / 1_000_000)
                break
    return (values[0], values[1])


def verify(actor) -> None:
    def trip(costing: str, start: dict, end: dict) -> dict:
        return actor.route(route_request(costing, start, end))["trip"]

    def maneuvers(result: dict) -> list[dict]:
        return result["legs"][0]["maneuvers"]

    forward = trip("auto", WEST, EAST)
    assert maneuvers(forward)[0]["street_names"] == ["One Way Street"]
    start = start_at(forward["legs"][0]["shape"])
    assert abs(start[0] - 47.500) < 0.000002
    assert abs(start[1] - WEST["lon"]) < 0.000002

    reverse_drive = trip("auto", EAST, WEST)
    reverse_walk = trip("pedestrian", EAST, WEST)
    assert "North Bypass" in {name for step in maneuvers(reverse_drive) for name in step.get("street_names", [])}
    assert reverse_drive["summary"]["length"] > 3 * reverse_walk["summary"]["length"]
    assert any(step["instruction"].startswith("Turn left") for step in maneuvers(reverse_drive))

    right_drive = trip("auto", WEST, SOUTH)
    right_walk = trip("pedestrian", WEST, SOUTH)
    assert maneuvers(right_walk)[1]["street_names"] == ["South Road"]
    assert maneuvers(right_drive)[1]["street_names"] == ["Southeast Road"]
    assert right_drive["summary"]["length"] > 2 * right_walk["summary"]["length"]
    print("Valhalla verified edge snapping, one-way streets, turn restrictions, and walking/driving maneuvers.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Fresh directory for the synthetic PBF, local graph, and log")
    parser.add_argument("--simulator", help="Explicit booted iOS Simulator UDID for the compiled Apple probe")
    args = parser.parse_args()
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    config = build_fixture(output)
    verify(valhalla.Actor(config))
    if args.simulator:
        root = Path(__file__).resolve().parents[2]
        probe = root / ".build/valhalla-probe/apple/iphonesimulator-valhalla-probe"
        timezone = root / ".build/routing/Routing/tzdata"

        class SimulatorActor:
            def route(self, request):
                response = subprocess.check_output(
                    ["xcrun", "simctl", "spawn", args.simulator, probe, timezone, config, json.dumps(request)],
                    text=True, timeout=45
                )
                return json.loads(response)

        verify(SimulatorActor())


if __name__ == "__main__":
    sys.exit(main())
