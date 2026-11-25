# Portland regional bundle

The Portland area edition combines the BBBike OpenStreetMap extract for places and routing with a separately extracted Protomaps v4 basemap. The source PBF declares west −122.965, south 45.334, east −122.362 and north 45.675. The rectangle includes Portland and parts of the surrounding Oregon and Washington suburbs.

The BBBike extract has edition `2026-11-21T00:00:00Z`, read from its replication timestamp. The publisher served 72,969,031 bytes with ETag `"4251243368"`. The local file matched the publisher MD5 `129a88d57cab0f20042d13dc38eac4f1` and has SHA-256 `7daa041b05f727fb35541e105ab86e748b1e4b80cb7cefca5de83f9a36e71804`. BBBike replaces the file at this URL when it publishes a newer extract. The versioned release retains the exact source used for the place index and routing graph. [BBBike extract](https://download.bbbike.org/osm/bbbike/Portland/) · [Publisher checksums](https://download.bbbike.org/osm/bbbike/Portland/CHECKSUM.txt)

The basemap uses the same pinned Source Cooperative parent object as Seattle. The Portland cutout includes zooms 6–15 and 3,450 tile entries. The app downloads the cutout from the kit release. [Versioned PMTiles object](https://data.source.coop/protomaps/openstreetmap/v4.pmtiles?versionId=440HxKhBAVMB.cR3WUFToSUubTpDm6b7)

The place index and routing graph retain ODbL 1.0 and OpenStreetMap contributor attribution. The basemap is an ODbL Produced Work with OpenStreetMap and Protomaps attribution. See the release notice for the exact source and the regional tooling guide for the build recipe. [BBBike extract terms](https://extract.bbbike.org/extract.html#tos) · [OpenStreetMap copyright](https://www.openstreetmap.org/copyright) · [Protomaps terms](https://docs.protomaps.com/basemaps/downloads) · [Build and release procedure](README.md#regional-catalog-bundle)

## Published files

The versioned edition uses a manifest pinned at SHA-256 `c914c7a343e71e313bd8b9e26605622149b65fde713ce82a969b70f120418665`. The download totals 293,367,270 bytes before temporary install space. [Portland data release](https://github.com/scottleibrand/TinFoilKit-iOS/releases/tag/region-portland-2026-11-21)

| File | Bytes | SHA-256 |
| --- | ---: | --- |
| Basemap | 61,494,058 | `de8a1e2fb3ea4b45ef9492ca2dd923bc2932bd6c35e1af66d7cf72516c459b8a` |
| Place index | 131,387,392 | `a95949b7a2331b0ebc5fdea369c0302fd86e192707d8da3f0a8a2fae5dcabe11` |
| Routing graph | 100,485,820 | `48a681c786cae0c915550bb2595c164c71edc60dd723f7f0578076f55f74df3b` |

In a dedicated simulator with a fresh lightweight install, set `TEST_RUNNER_TINFOILKIT_TEST_PUBLISHED_PORTLAND_REGION=1` and run `TinfoilKitUITests/LibraryAndMapsTests/testPublishedPortlandBundleInstallsAndRoutesAfterRelaunch`. The smoke test checks the installed basemap, finds Portland City Hall by street address and Legacy Good Samaritan by name, and opens both walking and driving steps after relaunch with exploratory downloads turned off.
