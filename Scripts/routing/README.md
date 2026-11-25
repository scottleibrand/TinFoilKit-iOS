# Offline Valhalla routing

The C bridge runs Valhalla with local graph tiles and a caller-provided JSON route request. The Apple engine is built from a pinned static archive and supplies no HTTP client.

## Mac route validation

Use Apple Silicon on macOS 15 or later with CPython 3.12 or later. The pinned Python wheel contains the macOS Valhalla actor and the tile builder. [Official wheel and hashes](https://pypi.org/project/pyvalhalla/3.9.3/)

```sh
python3 -m venv .build/valhalla-probe/venv
.build/valhalla-probe/venv/bin/python -m pip install --only-binary=:all: pyvalhalla==3.9.3 osmium==4.2.0
.build/valhalla-probe/venv/bin/python Scripts/routing/smoke-valhalla.py .build/valhalla-probe/fixture-run
```

Use a fresh output directory for each run. The fixture is synthetic and generated from checked-in OSM XML. There is no API server or online routing during the test. Assertions cover an interior edge snap, walking and driving maneuvers, a driving detour for the reverse direction of a one-way street, and enforcement of a prohibited car turn.

## Apple build and link validation

```sh
bash Scripts/routing/prepare-apple-routing.sh
bash Scripts/routing/build-apple-probe.sh
```

Preparation verifies the release, configuration and timezone SHA-256 hashes. It writes `.build/routing/TFKValhalla.xcframework` and `.build/routing/Routing` with the configuration, IANA timezone data and dependency notices. The probe links the resulting framework for iOS 17 arm64 devices and both arm64 and x86_64 simulators. Link the static library with C++, zlib and Core Foundation. Copy the `Routing` directory into the app bundle. [Release](https://github.com/Rallista/valhalla-mobile/releases/tag/0.6.6) · [Upstream checksum](https://github.com/Rallista/valhalla-mobile/blob/d03c3f51925f9e0211013a6e90a69dd216654810/Package.swift)

When a dedicated iOS simulator is running, pass its explicit UDID to the fixture script with `--simulator`. The same tests will exercise the compiled Apple probe using its local graph. The current simulator service did not launch the probe during verification. Apple runtime behavior and cross-version tile compatibility remain to be verified. The Apple binary contains Valhalla 3.9.2 at `a919bb6b64d61d12f79ea5466d5cf599a39714ad`, while the Mac wheel contains 3.9.3. Generate release graph packs with the same engine version as the client and include the graph version, extent, attribution and checksums. [Embedded engine commit](https://github.com/valhalla/valhalla/commit/a919bb6b64d61d12f79ea5466d5cf599a39714ad)

The bridge owns an opaque actor. Hold one actor per routing configuration and serialize its calls. A successful bridge call can return a Valhalla JSON error object. Handle this before decoding the route. Read the pinned default configuration from the app bundle, override its graph paths and cache size, and set the bundled timezone directory before opening an actor. [Turn-by-turn request and response](https://valhalla.github.io/valhalla/api/turn-by-turn/api-reference/) · [Pinned default configuration](https://github.com/Rallista/valhalla-mobile/blob/d03c3f51925f9e0211013a6e90a69dd216654810/apple/Sources/Valhalla/SupportData/default.json)

## Licenses and distribution

- Valhalla Mobile 0.6.6 and Valhalla 3.9.2 use MIT. This prototype's original C bridge and fixture use the repository MIT license. [Mobile license](https://github.com/Rallista/valhalla-mobile/blob/d03c3f51925f9e0211013a6e90a69dd216654810/LICENSE.md) · [Engine license](https://github.com/valhalla/valhalla/blob/a919bb6b64d61d12f79ea5466d5cf599a39714ad/COPYING)
- The pinned vcpkg baseline resolves Boost 1.92.0 under the Boost Software License, Protobuf Lite v33.4 and its MIT-licensed UTF-8 range source, Abseil 20260107.1 under Apache-2.0, the LZ4 1.10.0 library under BSD-2-Clause, and RapidJSON at `24b5e7a` under MIT and included third-party terms. The distribution needs their full notices where applicable. This inventory uses the source manifest and the library merge recipe. [Manifest](https://github.com/Rallista/valhalla-mobile/blob/d03c3f51925f9e0211013a6e90a69dd216654810/src/vcpkg.json) · [Packaged libraries](https://github.com/Rallista/valhalla-mobile/blob/d03c3f51925f9e0211013a6e90a69dd216654810/src/CMakeLists.txt) · [vcpkg baseline](https://github.com/microsoft/vcpkg/blob/9eec002df1cd109f8f104cd966a763daf9751489/versions/baseline.json)
- The pinned Valhalla tree also includes the MIT Date library with per-file authorship, MIT cpp-statsd-client, Flatbush, microtar and unordered_dense, and BSD-licensed protozero and vtzero. Preserve notices from the exact linked commits and the bundled timezone data. The reference mobile timezone tar contains IANA 2025b and its own notice for public-domain material and any BSD-derived files. [Valhalla dependencies](https://github.com/valhalla/valhalla/tree/a919bb6b64d61d12f79ea5466d5cf599a39714ad/third_party) · [IANA tzdb 2025b license](https://data.iana.org/time-zones/tzdb-2025b/LICENSE)
- Graph packs derived from production OpenStreetMap extracts need their own ODbL attribution and derivative database distribution terms. The synthetic fixture needs no OSM extract. [OpenStreetMap licensing](https://www.openstreetmap.org/copyright)

The upstream Apple zip contains the static libraries and headers. Preparation supplies the notice bundle from upstream sources, including individual copyright notices and Apache notices where applicable.

## Regional catalog bundle

Use the bundle tool to prepare a place index and routing pack from the same pinned extract. It requires Python 3.10 or later, `osmium==4.2.0`, and Docker with the pinned Valhalla image. Use the publisher's exact edition and verified SHA-256. Set the artifact base URL to the intended HTTPS directory for that edition.

```sh
python Scripts/build-regional-bundle.py build region.osm.pbf .build/region-bundle \
  --region 'Region name' --data-version YYYY-MM-DD \
  --source https://publisher.example/region.osm.pbf --source-sha256 "$REGIONAL_EXTRACT_SHA256" \
  --artifact-base-url https://catalog.example/region/YYYY-MM-DD/ \
  --bounds WEST SOUTH EAST NORTH
python Scripts/build-regional-bundle.py verify .build/region-bundle
```

The output directory contains `places.sqlite`, `routing.tfkroute` and `manifest.json`. The catalog manifest records the source hash, edition, bounds, attribution, license and the URL, SHA-256 and byte count of each installable artifact. Verification checks the local files against that manifest, including the embedded graph digest and matching place and route metadata. Publish the files and reviewed manifest through a trusted catalog channel. The manifest itself carries no signature.

To include a separately sourced basemap, add these arguments to the build command. Use a PMTiles v3 archive with Mapbox Vector Tiles and a tile schema compatible with the app's Protomaps style. The app supports uncompressed or gzip-compressed PMTiles sections. Use the exact byte count and SHA-256 of the local PMTiles file. [PMTiles specification](https://github.com/protomaps/PMTiles/blob/main/spec/v3/spec.md)

```sh
  --basemap region.pmtiles --basemap-edition BASEMAP_REVISION \
  --basemap-source https://basemap-publisher.example/region.pmtiles \
  --basemap-license ODbL-1.0 --basemap-license-url https://www.openstreetmap.org/copyright \
  --basemap-attribution '© OpenStreetMap contributors · Protomaps' \
  --basemap-byte-count "$BASEMAP_BYTES" --basemap-sha256 "$BASEMAP_SHA256"
```

Two-artifact bundles use schema version 1. A basemap adds `basemap.pmtiles` and uses schema version 2. Its `assets.basemap` entry adds `dataVersion`, `source`, `license`, `licenseURL`, `attribution` and `bounds` alongside `filename`, `url`, `byteCount` and `sha256`. The basemap's own bounds come from the PMTiles header and must contain the full region. The check uses declared bounds. Assess tile and zoom coverage for the intended area before publishing. The basemap keeps its own publisher attribution and terms. The place and routing artifacts keep the manifest's top-level OpenStreetMap attribution and terms. In the app, choose **Map → + → Import regional bundle**, open the output folder in Files, and confirm the selection.

Production extracts use OpenStreetMap data. Preserve the copyright notice, ODbL terms and source edition when redistributing the files. Verify additional publisher terms before publishing. Keep downloaded extracts, generated indexes and routing graphs out of Git.

### Stage an edition for publication

After the artifacts pass verification, use `stage-release` to assign their final URLs without rebuilding. Pass the exact source extract and the authorized HTTPS directory for the immutable edition.

```sh
python Scripts/build-regional-bundle.py stage-release .build/region-bundle region.osm.pbf .build/region-release \
  --artifact-base-url https://catalog.example/region/YYYY-MM-DD/
```

This command verifies the bundle before and after staging, checks the archived PBF against the manifest, and creates a data notice. Host the installable assets, `NOTICE.md` and `source.osm.pbf` alongside `manifest.json` in the edition directory. The source extract and notice are for database access and attribution. The app downloads only the files listed under `assets`. After uploading, fetch the manifest to compare its SHA-256 with the printed pin and confirm that each asset serves HTTP 206 with the requested range and the manifest's exact total size. Pin the final URL and hash through the app's trusted catalog after those checks.

The [Seattle](SEATTLE-CANDIDATE.md) and [Portland](PORTLAND.md) editions record source editions, checksums and production download checks.

Run the end-to-end producer fixture with the same Python and Docker setup.

```sh
python Tests/RegionalBundleFixture/run.py
```

The test converts the pinned, original MIT-licensed synthetic network to PBF with an invented pharmacy and address. It also generates a separate MIT-licensed PMTiles file with one synthetic vector tile. It checks both manifest versions, basemap provenance, coverage, size and hashes, release URL rebasing and source retention, and rejection of malformed or changed artifacts. The temporary builds stay under the ignored `.build/` directory.
