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
