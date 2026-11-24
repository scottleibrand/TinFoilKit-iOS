# Seattle regional bundle candidate

This candidate uses the BBBike Seattle extract for places and routing, with separately sourced Protomaps v4 vector tiles. It covers west `-122.462`, south `47.394`, east `-122.005`, north `47.831`. These bounds come from the PBF header and cover the BBBike rectangle, including Seattle and parts of neighboring cities.

## Edition and provenance

| Input | Verified on 2026-11-24 |
| --- | --- |
| Seattle OpenStreetMap PBF | Edition `2026-11-21T00:00:00Z` in the PBF header. The file was served with Last-Modified `2026-11-21 17:10:57 UTC`, ETag `"3068425374"`, and exactly 69,666,432 bytes. The downloaded file matched BBBike's published MD5 `04a61a079be3b93ae194a4bb17e77288`; its SHA-256 was `f3a6581e68bca74d2d1951c557eadda953dc32be94d5463bfe91c637944ad994`. The URL rolls forward, so retain this verified edition or fetch a new edition and derive a new pin. [Seattle download](https://download.bbbike.org/osm/bbbike/Seattle/) · [Publisher checksums](https://download.bbbike.org/osm/bbbike/Seattle/CHECKSUM.txt) |
| Protomaps v4 parent PMTiles | Source Cooperative object version `440HxKhBAVMB.cR3WUFToSUubTpDm6b7`, Last-Modified `2026-03-31 14:59:51 UTC`, ETag `"9e09dd251e816c0ea9208e1e34c28eba-2572"`, 134,812,420,554 bytes. A 127-byte GET returned HTTP 206 and the expected version, ETag, and total size. [Versioned PMTiles object](https://data.source.coop/protomaps/openstreetmap/v4.pmtiles?versionId=440HxKhBAVMB.cR3WUFToSUubTpDm6b7) · [Source Cooperative dataset](https://source.coop/protomaps/openstreetmap) |
| Extracted Seattle basemap | Verified PMTiles v3 with gzip-compressed vector tiles, zooms 6–15, 3,355 tile entries, exactly 56,567,765 bytes, SHA-256 `3a9e7dac357d28b9afbe41a778b5f365d9787f2fedcc29192398244b01dfdb53`. The archive header matches the BBBike bounds. Its declared layers include the app's Protomaps style layers `boundaries`, `buildings`, `landcover`, `landuse`, `roads` and `water`. The extract transferred about 59 MB across 49 requests. |

BBBike identifies the OSM data as ODbL 1.0 and applies fair-use terms to its extract service. The place index and route graph are derived databases. Publish them under ODbL with `© OpenStreetMap contributors`, the exact source edition, and the license and access notice. Use the published artifacts to provide machine-readable access to those databases and retain the pinned source and build recipe. Protomaps distributes the basemap as an ODbL Produced Work requiring OpenStreetMap attribution. Carry `© OpenStreetMap contributors · Protomaps` with the local extract. Natural Earth source data is public domain. [BBBike extract terms](https://extract.bbbike.org/extract.html#tos) · [OpenStreetMap copyright](https://www.openstreetmap.org/copyright) · [ODbL §§4.3–4.6](https://opendatacommons.org/licenses/odbl/1-0/) · [Protomaps terms](https://docs.protomaps.com/basemaps/downloads) · [Natural Earth terms](https://www.naturalearthdata.com/about/terms-of-use/)

## Build locally

Use Python with `osmium==4.2.0`, Docker, and the pinned Valhalla image used by the regional builder. On Linux x86-64 the official go-pmtiles 1.31.2 archive is 17,444,324 bytes with SHA-256 `3ed7dbf4ec2e6dfe5e25b6f70d1ffc932729f93c86db353bf514dd71010a312f`. Extract its `pmtiles` executable into `.build/seattle/`, or use the same release for your platform. [go-pmtiles release](https://github.com/protomaps/go-pmtiles/releases/tag/v1.31.2)

On Linux, fetch and verify the pinned BBBike edition and extract the versioned basemap.

```sh
mkdir -p .build/seattle
source_url=https://download.bbbike.org/osm/bbbike/Seattle/Seattle.osm.pbf
source_sha=f3a6581e68bca74d2d1951c557eadda953dc32be94d5463bfe91c637944ad994
curl --proto '=https' -fSL --max-time 120 --max-filesize 69666432 \
  -H 'If-Match: "3068425374"' -o .build/seattle/Seattle.osm.pbf "$source_url"
printf '%s  %s\n' "$source_sha" .build/seattle/Seattle.osm.pbf | sha256sum -c -

basemap_url='https://data.source.coop/protomaps/openstreetmap/v4.pmtiles?versionId=440HxKhBAVMB.cR3WUFToSUubTpDm6b7'
.build/seattle/pmtiles extract "$basemap_url" .build/seattle/Seattle-v4.pmtiles \
  --bbox=-122.462,47.394,-122.005,47.831 --minzoom=6 --maxzoom=15 --download-threads=2
.build/seattle/pmtiles verify .build/seattle/Seattle-v4.pmtiles
```

The bundle command checks the verified PMTiles size and SHA-256. The reserved artifact URL below is suitable for a local Files import. For a download edition, replace it with an authorized versioned HTTPS directory and compute the final manifest SHA-256 after setting the release URLs.

```sh
python3 Scripts/build-regional-bundle.py build .build/seattle/Seattle.osm.pbf .build/seattle/bundle \
  --region 'Seattle area' --data-version '2026-11-21T00:00:00Z' \
  --source "$source_url" --source-sha256 "$source_sha" \
  --artifact-base-url https://example.invalid/regional/seattle/2026-11-21/ \
  --bounds -122.462 47.394 -122.005 47.831 \
  --basemap .build/seattle/Seattle-v4.pmtiles \
  --basemap-edition 'Protomaps v4 440HxKhBAVMB.cR3WUFToSUubTpDm6b7' \
  --basemap-source "$basemap_url" \
  --basemap-license ODbL-1.0 --basemap-license-url https://www.openstreetmap.org/copyright \
  --basemap-attribution '© OpenStreetMap contributors · Protomaps' \
  --basemap-byte-count 56567765 \
  --basemap-sha256 3a9e7dac357d28b9afbe41a778b5f365d9787f2fedcc29192398244b01dfdb53
python3 Scripts/build-regional-bundle.py verify .build/seattle/bundle
```

## Build and smoke checks

The version 2 manifest and all three artifacts passed the regional bundle verifier on Linux with Valhalla 3.9.2. The download totals 318,339,726 bytes before temporary install space. These hashes identify the observed build. Routing graph builds can vary by tile creation date.

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| `basemap.pmtiles` | 56,567,765 | `3a9e7dac357d28b9afbe41a778b5f365d9787f2fedcc29192398244b01dfdb53` |
| `places.sqlite` | 125,927,424 | `c1eee8a262b97fa58803ca2305ed0404d71274db8cd9744d2c8182b5ac8f5021` |
| `routing.tfkroute` | 135,844,537 | `88b9b01c17d67e22cceb9226602c88af57b7b31066f9112736ab5eab23fcba05` |

- The 554,730-record place index returned `325 9th Avenue, Seattle, 98104` from an address search and Swedish First Hill Medical Center from a Swedish hospital search. This edition tags the Harborview Medical Center way as `amenity=doctors` and `healthcare=doctor`, so the current builder groups it with urgent care. Its name and address remain searchable. Review important service classifications for the release edition. [OSM way 169511257](https://www.openstreetmap.org/way/169511257)
- The 183-tile graph returned walking and driving instructions in Valhalla's network-disabled one-shot mode. Pike Place Market to Swedish First Hill Medical Center was 1.941 km walking with 31 maneuvers and 2.189 km driving with 7 maneuvers.
- A public download needs an authorized HTTPS release location and a trusted final manifest digest. Run the three-asset Files import, map rendering, search, route steps and removal on an iPhone in airplane mode before release.
