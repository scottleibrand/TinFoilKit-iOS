# Routing pack tests

Run the format and tile-index checks with Python 3.10 or later.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 Tests/RoutingPackFixture/test_routing_pack.py
```

The production builder also needs Docker. Run it with a local OpenStreetMap PBF extract, its bounding box, and its publisher and version metadata.

```sh
python3 Scripts/build-regional-routing-pack.py region.osm.pbf region.tfkroute \
  --region 'Region name' --bounds WEST SOUTH EAST NORTH \
  --source 'https://publisher.example/region.osm.pbf' --data-version 2026-11-21
```

The builder pins the official Valhalla 3.9.2 container by digest for ARM64 and AMD64 and checks its reported version. The upstream release workflow builds from the release tag and embeds a short Git revision only for builds from master. It creates a seekable graph with the upstream tile extractor, validates the offsets and IDs, and writes the source and graph hashes into the pack manifest. The build runs without container network access. Valhalla records tile creation dates, so a repeated build can yield a different graph hash for the same input. [Release tag](https://github.com/valhalla/valhalla/releases/tag/3.9.2) · [Release workflow](https://github.com/valhalla/valhalla/blob/a919bb6b64d61d12f79ea5466d5cf599a39714ad/.github/workflows/docker-build.yml)

Use `--admin-database` and `--timezone-database` when you have matching Valhalla spatial databases. These databases are separate from the iOS timezone resource named by the manifest. Keep OpenStreetMap attribution and ODbL terms with any derived pack you distribute.
