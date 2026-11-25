# Third-party software, data and content

The iOS project's own code and documentation are [MIT](LICENSE). Third-party software and data retain their own licenses. Build scripts prepare dependencies under `.build/` and check the expected ETag for the Seattle map source. The app downloads content packs from their publishers or official mirrors when a user chooses them.

The full license texts that ship inside the app are collected during preparation:

- [Scripts/prepare-zim-reader.sh](Scripts/prepare-zim-reader.sh) writes the Rust crate and SwiftSoup notices to `.build/notices/`.
- [Scripts/prepare-map-assets.sh](Scripts/prepare-map-assets.sh) copies the MapLibre and Noto Sans licenses to `.build/map-assets/`.
- [Scripts/routing/prepare-apple-routing.sh](Scripts/routing/prepare-apple-routing.sh) writes the routing engine notices listed in [Scripts/routing/notice-sources.tsv](Scripts/routing/notice-sources.tsv).

## Linked into the app

| Component | Version | License |
| --- | --- | --- |
| [zimru](https://github.com/jasontitus/zimru), the ZIM reader | revision `cbafcb4` | MIT |
| [SwiftSoup](https://github.com/scinfu/SwiftSoup) | 2.14.4 | MIT |
| [MapLibre Native for iOS](https://github.com/maplibre/maplibre-native) | 6.29.0 | BSD-2-Clause |
| [Valhalla Mobile](https://github.com/Rallista/valhalla-mobile), the routing engine | 0.6.6 | MIT |

zimru links these Rust crates, at the versions in [ReaderBridge/Cargo.lock](ReaderBridge/Cargo.lock):

| Crate | License |
| --- | --- |
| bitflags, crc, crc-catalog, errno, libc, md5, thiserror, zstd-rs | MIT or Apache-2.0 |
| chksum-hash-core, chksum-hash-sha2-256 | MIT |
| lzma-rust2 | Apache-2.0 |
| rustix | Apache-2.0 with LLVM exception, Apache-2.0, or MIT |

proc-macro2, quote, syn, thiserror-impl and unicode-ident (MIT or Apache-2.0, plus Unicode-3.0 for unicode-ident) run only while compiling.

Valhalla Mobile packages Valhalla and its dependencies. [Scripts/routing/README.md](Scripts/routing/README.md) records the exact revisions.

| Component | License |
| --- | --- |
| Valhalla | MIT |
| Boost | Boost Software License 1.0 |
| Protocol Buffers Lite | BSD-3-Clause; its UTF-8 range code is MIT |
| Abseil | Apache-2.0 |
| LZ4 and xxHash | BSD-2-Clause |
| RapidJSON | MIT, with the third-party terms in its license file |
| Howard Hinnant's date library, cpp-statsd-client, Flatbush, microtar, unordered_dense | MIT |
| protozero | BSD-2-Clause; code derived from Folly is Apache-2.0 |
| vtzero | BSD-2-Clause, with the external terms in its license files |
| IANA time zone database | Public domain |

## Bundled assets

- **App icon:** adapted from `mac/AppIcon.icns` in [Tinfoil Kit](https://github.com/tudor-city-ventures/tinfoil-kit) at revision `6417927`, © 2026 Tudor City Ventures, MIT. The notice is in [Sources/TinfoilKit/TinfoilKit-Icon-LICENSE.txt](Sources/TinfoilKit/TinfoilKit-Icon-LICENSE.txt).
- **Map font:** Noto Sans Regular glyphs from [protomaps/basemaps-assets](https://github.com/protomaps/basemaps-assets), © The Noto Project Authors, SIL Open Font License 1.1.
- **Seattle basemap:** tiles from the [Protomaps v4 basemap on Source Cooperative](https://source.coop/protomaps/openstreetmap), which Protomaps distributes as an ODbL Produced Work. The basemap includes OpenStreetMap and Natural Earth data. [Protomaps basemap terms](https://docs.protomaps.com/basemaps/downloads)
- **Seattle place index and routing graphs:** derived from OpenStreetMap data, © OpenStreetMap contributors, under the [Open Database License](https://www.openstreetmap.org/copyright). The legacy walking graph uses a [BBBike extract](https://download.bbbike.org/osm/bbbike/Seattle/). Optional `.tfkroute` bundles and imported regional place indexes retain the source data's terms. The app shows OpenStreetMap attribution on the map.

## Downloaded by the app

- **Map tiles:** the app's tile cache reads the same Protomaps v4 basemap, with the same OpenStreetMap attribution and license.
- **Content packs:** downloaded from Kiwix and its official mirrors when a user chooses them. Each pack lists its own attribution and terms in Content Packs. In summary:
  - Wikipedia packs and Appropedia: CC BY-SA. Images carry their own licenses.
  - iFixit: CC BY-NC-SA 3.0, which prohibits commercial use.
  - The water and field medicine libraries: collections of documents under their authors' individual terms.
- **Printable references:** Household prints page ranges from installed packs. They include *Where There Is No Doctor* (Hesperian Health Guides) and Washington State Department of Health guidance, under their publishers' terms.

### Publisher book discovery

The app searches the official Kiwix OPDS catalog and reads per-edition Metalink metadata from Kiwix. The result carries publisher attribution, exact file size and SHA-256. The app can download a selected edition or verify a copy supplied through Files. Discovered editions are for local use and carry the terms of their original works. The app includes its own catalog and Metalink readers. [Kiwix catalog](https://library.kiwix.org/) · [Kiwix terms](https://get.kiwix.org/en/terms-conditions/)

The Spanish Wikipedia highlights edition `2026-10` can fall back from FAU to Wikimedia using the same publisher SHA-256. Kiwix lists both locations for the 217,314,941-byte edition. [Kiwix Metalink](https://download.kiwix.org/zim/wikipedia/wikipedia_es_top_mini_2026-10.zim.meta4)

## Build and test tools

These run on the developer's Mac and aren't shipped in the app.

| Tool | License |
| --- | --- |
| [go-pmtiles](https://github.com/protomaps/go-pmtiles) 1.31.2 | BSD-3-Clause |
| [@mapbox/vector-tile](https://github.com/mapbox/vector-tile-js) 2.0.4 and [pbf](https://github.com/mapbox/pbf) 4.0.1 | BSD-3-Clause |
| [pyosmium](https://github.com/osmcode/pyosmium) 4.2.0 | BSD-2-Clause |
| [pyvalhalla](https://pypi.org/project/pyvalhalla/) 3.9.3 | MIT |
| zimru's `zimwriterfs`, for the PDF test archive | MIT |
| [XcodeGen](https://github.com/yonaskolb/XcodeGen) | MIT |

## Test fixtures

- `climate.zim`, downloaded from openzim's [zim-testing-suite](https://github.com/openzim/zim-testing-suite) at a pinned revision: Wikipedia content, CC BY-SA.
- [Tests/ZIMArchiveTests/Fixtures/pdf-collection.zim](Tests/ZIMArchiveTests/Fixtures/pdf-collection.zim), the OpenStreetMap XML under [Tests/RegionalPlaceIndexFixture](Tests/RegionalPlaceIndexFixture), and [Scripts/routing/fixture.osm](Scripts/routing/fixture.osm) are synthetic and part of this project under MIT. They don't describe real places.
