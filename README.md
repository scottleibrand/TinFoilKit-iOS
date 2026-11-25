# Tinfoil Kit for iOS

Tinfoil Kit puts a reference library, maps, and your household’s emergency notes on your iPhone. Download what you need while you’re connected, then look up a repair, check a map, or find your family’s meeting point when cell service is down or you’re traveling out of coverage.

[Build it from source](#build-locally) to set up a kit for the places you go and the people you plan with. Start with a few guides and a local map, then try them in airplane mode so you know what you’ll have when you need it.

This app is based on the original desktop Tinfoil Kit by Travis Bloom and Tudor City Ventures. [Desktop repository](https://github.com/tudor-city-ventures/tinfoil-kit) · [Official website](https://tinfoilkit.com/)

## Using the app

Download packs individually over Wi-Fi or choose **Download Essentials** or **Download all** to get packs in bulk. To allow cellular data for a transfer, open its download options and review the size. Filter by language in Content Packs to find English and Spanish editions. Start WikiMed Medical Encyclopedia (about 2.3 GB) and either complete English Wikipedia edition individually. The text-only Wikipedia archive is about 53 GB, and the edition with images is about 127 GB. Indexing needs additional free space. [WikiMed manifest](https://download.kiwix.org/zim/other/mdwiki_en_all_maxi_2025-11.zim.meta4) · [Text-only Wikipedia manifest](https://download.kiwix.org/zim/wikipedia/wikipedia_en_all_nopic_2026-06.zim.meta4) · [Illustrated Wikipedia manifest](https://download.kiwix.org/zim/wikipedia/wikipedia_en_all_maxi_2026-08.zim.meta4)

Pack downloads retry after temporary connection failures and publisher errors. A saved cellular transfer can be resumed from its own row, and the button indicates that cellular data is allowed. Bulk downloads use Wi-Fi. When the publisher supports resuming and iOS still has the partial file, the retry picks up where it left off. Otherwise it starts the file again. [Apple’s download resumption guide](https://developer.apple.com/documentation/foundation/pausing-and-resuming-downloads)

To install existing catalog editions offline, open **Library → Content Packs → Install catalog packs from Files** and select the folder containing the original ZIM files. For a desktop kit or drive, select `downloads/library`. Review the editions and their sizes before installing. Matches are copied and verified against the catalog’s publisher checksums, starting with the smallest. A stopped batch keeps the completed packs and the originals. For an edition missing from the catalog, use **Import from Files** in Library. Regional bundles and household backups have their own import controls. [Desktop kit on another computer](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/GUIDE.md#on-another-computer)

Press and hold an installed archive in Library to verify its checksum or remove it. Catalog packs use the publisher’s SHA-256 checksum. Other ZIM imports use the archive’s embedded checksum to check for corruption. Catalog packs also support repair and updates. Repair replaces a same-edition copy after checksum verification. An update keeps the earlier edition and its index available until the new one is verified and searchable.

Library and Ask can search article text and PDF pages as indexes build. Indexing resumes after an interruption when storage is available. Results from PDFs open to the matching page. Ask can stream a cited answer on devices with Apple Intelligence, and you can turn its on-device model off from the options menu.

Open **Ask options → Offline Chat** for a conversation with the model on your phone. It needs Apple Intelligence and iOS 26 or later. The conversation lasts while the chat is open. Use Ask for answers that cite your saved references. [Apple’s on-device models](https://developer.apple.com/foundation-models-framework/)

In an open article, use the archive back and forward buttons to retrace followed links, and **Find on page** to search the current article. In a PDF, use **Find in document** to jump between matches. Both reader searches work offline.

Use **Add bookmark** in an article or PDF, then reopen it under **Library → Reading list**. The list also keeps recent reading and reopens PDFs on the page you were viewing. Clearing recent reading keeps your bookmarks.

When local evidence is insufficient, use **Ask online** to search Google or copy the question and open ChatGPT, Claude, or Gemini without an API key. These results open outside Tinfoil Kit. To ask inside Tinfoil Kit, add a provider’s API key under **Ask options → Online providers**. The app sends the question after you choose a provider and keeps API keys in the device’s Keychain. Future offline searches can use saved GPT or Claude answers, citation details, and readable source copies when available. Gemini grounding stays in the online session because Google restricts indexing and reuse of grounded responses and links. [Google grounding terms](https://ai.google.dev/gemini-api/terms#grounding-with-google-search)

After finding an article or PDF in your browser, copy its link and paste it into **Ask online → Save a web source**. You can also open **Saved web sources** from Ask options. Ask can cite readable text the publisher allows the app to save, and you can reopen or remove the source from that list. These copies stay on the device.

Use **Library → Content packs → Find publisher books** to search Kiwix for more offline archives. This sends your typed search to Kiwix. Open a result and choose **Check publisher file** for the exact size and SHA-256. Choose **Download** for Wi-Fi or explicitly allow cellular in the download options. **Publisher downloads** in Content Packs shows approved transfers after relaunch, with pause, resume, and retry controls. The app installs the archive for offline reading and search after verification. You can also save the archive from Kiwix to Files and choose **Verify and import downloaded ZIM**.

For questions about water service during a power outage, include your utility or service area. Ask looks for a saved reference that matches the area and quotes the passage if it gives an operating duration. The cited source shows which facilities and conditions the statement covers.

With Home set and regional place data installed, ask “Where’s the nearest pharmacy?” or “Find a hospital near home.” Ask finds the closest matching place in the installed data and shows its straight-line distance from Home. Open the result in Map or choose **Open in Google Maps** to pass along the destination coordinates. The Google Maps option is also available for selected places and dropped pins in Map. [Google Maps links](https://developers.google.com/maps/documentation/urls/get-started)

The Map tab saves tiles as you pan, zoom, or follow your location. Saved tiles stay in the app’s durable storage and remain available across launches. Basemap tiles use the Protomaps archive hosted by Source Cooperative. Library indexing continues while you use the Map tab. [Protomaps OpenStreetMap data](https://source.coop/protomaps/openstreetmap)

Open **Map → + → Map downloads** to limit automatic downloads to Wi-Fi or turn them off. The tile provider receives requests for the areas you view. You can check how much space saved tiles use or clear them. Clearing turns automatic downloads off and leaves bundled and imported maps available.

Use **Map → + → Import map tiles** to add a regional PMTiles basemap from Files. **Installed basemaps** shows each map’s coverage and lets you switch between regions offline. Swipe a standalone basemap to remove it.

Use **Map → + → Import regional bundle** and select a folder containing `manifest.json`, `places.sqlite`, and `routing.tfkroute`. A version 2 bundle also contains `basemap.pmtiles`. The app verifies and installs the files together and selects a basemap included in the bundle. Use **Installed regional bundles** to see the editions and sources or remove the bundle. You can still import a basemap separately for a version 1 bundle. [Regional bundle builder](Scripts/routing/README.md#regional-catalog-bundle)

Open **Map → + → Download regional bundle**. Choose a named region when the built-in catalog has one, or enter a publisher’s HTTPS manifest URL and its trusted SHA-256. Tap **Review download** to verify the manifest and see the edition, coverage, size, and terms. Tap **Download and install** to fetch the files. Cellular data is off by default, and a pending job keeps the network setting chosen at review. You can pause and reopen **Download regional bundle** to resume or discard the pending job after relaunch. A publisher with a strong ETag and byte-range support can resume from the last verified checkpoint. The app verifies all files before installing the bundle. Publishing a named entry requires a version 2 bundle at an authorized host and the final manifest pin.

In Map, press and hold a location to copy its coordinates, set it as home, or save a named pin. Map search accepts saved place names and coordinates such as `40.7128, -74.0060`, `40.7128 N 74.0060 W`, and `40°42′46″N 74°0′22″W`. The Household tab keeps notes, home, and pins on the device.

In **Household → Import and export**, save a household backup to Files or restore one on another iPhone. The same screen imports and exports the desktop kit’s `notes.txt` and `places.json` files individually. If the local household file is damaged, restoring a backup or starting a new household keeps a separate copy of the damaged file.

In **Household → Share on local network**, select the household details to share and start a browser session on a trusted Wi-Fi or Ethernet network with IPv4. The link uses unencrypted HTTP. Anyone on that network who has the link or can watch its traffic can read the selection. The session ends after ten minutes, when you leave the screen, or when you stop it.

Use Print the Essentials in Household for a printable copy of your household information and selected pages from installed references. Install a regional place index to include the nearest services to your saved home.

To build a regional address and service index, install `osmium==4.2.0` and run `python Scripts/build-regional-place-index.py region.osm.pbf region.sqlite --region "Region name" --source https://provider.example/region.osm.pbf`, using the actual source URL. Import the resulting SQLite file from Map. Address search and nearby services use all installed regional indexes, regardless of the active basemap. Open **Map → + → Installed place data** to review or remove an index and see its source and attribution.

Import compatible `.tfkroute` packs from Map, then tap **Directions** to choose **From**, **To**, and a travel mode. The starting point defaults to saved Home when available. Pick a saved pin, current position, an address from installed place data, or coordinates. You can swap the endpoints before calculating the route and tap individual steps to find them on the map. A routing pack must cover both endpoints. Open **Map → + → Installed routing packs** to check coverage or remove a pack. Build a graph from a regional OSM extract with `python Scripts/build-regional-routing-pack.py --help`. Routing packs are separate from basemap tiles and place indexes. [Routing engine and graph formats](Scripts/routing/README.md)

To make a graph available for installation from the app bundle, place its `.tfkroute` file in `.build/routing-packs/` before running XcodeGen. Routing preparation creates this folder even when no graphs are bundled.

Open **Offline readiness** from the Library toolbar to check storage, installed content, indexing progress, model availability, and map coverage before a trip.

Open **Library → Find nearby** to see nearby devices. Enable **Sync public references** on both devices to automatically receive and relay the verified household check-in worksheet while using any part of the app. The standard build supplies the worksheet, and the lightweight build can receive it for offline reading. Switching apps pauses discovery and lets an active transfer finish if iOS grants it time. [Nearby sharing plan](DISASTER-SHARING.md) · [Apple background execution](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)

Turn on **Notify me about interrupted downloads** in Nearby to get a rate-limited alert when a receive already underway stops in the background. Tap the alert to reopen Tinfoil Kit and let Nearby sync try again.

## Build locally

Use an Apple Silicon Mac with Xcode 26 or later, XcodeGen, Rust, Node.js, and Python 3. Preparation downloads the reader, map and routing dependencies plus a public ZIM test fixture. Generated files and external data are stored in `.build/`.

```sh
rustup target add aarch64-apple-ios-sim
bash Scripts/prepare-map-assets.sh
bash Scripts/routing/prepare-apple-routing.sh
bash Scripts/prepare-zim-reader.sh
xcodegen generate
xcodebuild build -project TinfoilKit.xcodeproj -scheme TinfoilKit \
    -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' \
    -derivedDataPath .build/AppDerivedData CODE_SIGNING_ALLOWED=NO
```

For a device build, add the Rust target `aarch64-apple-ios`, run `bash Scripts/prepare-zim-reader.sh device`, and select your development team and phone in Xcode.

To enable Seattle walking previews, download the Seattle PBF from BBBike, install `osmium==4.2.0` in a local Python environment, and run `python Scripts/build-walking-graph.py Seattle.osm.pbf .build/map-assets/seattle-walking.sqlite` before building. The walking graph and place database use OpenStreetMap data under ODbL 1.0. [BBBike Seattle extract](https://download.bbbike.org/osm/bbbike/Seattle/) · [OpenStreetMap attribution and license](https://www.openstreetmap.org/copyright)

### Lightweight release profile

The lightweight profile bundles the map engine, glyphs and notices. Install regional data separately. The offline disaster starter guide opens on first launch and remains available in Library. The default development project can still bundle the Seattle map and test routing packs.

After preparing the device Rust reader and Apple routing engine, build and measure the lightweight profile locally.

```sh
bash Scripts/prepare-map-assets.sh --lightweight
xcodegen generate --spec project-lightweight.yml
xcodebuild build -project TinfoilKitLightweight.xcodeproj -scheme TinfoilKit \
    -configuration Release -destination generic/platform=iOS \
    -derivedDataPath .build/LightweightDeviceDerivedData CODE_SIGNING_ALLOWED=NO
ditto -c -k --keepParent \
    .build/LightweightDeviceDerivedData/Build/Products/Release-iphoneos/TinfoilKit.app \
    .build/TinfoilKit-lightweight.zip
wc -c .build/TinfoilKit-lightweight.zip
```

The local ZIP measures this build. Use App Store Connect device-specific size reports for the distribution download size. [Nearby disaster-sharing plan](DISASTER-SHARING.md)

## Test

On an Apple Silicon Mac with Xcode, prepare the Rust targets listed above and run the candidate checks on a dedicated simulator. The runner keeps app and archive test results in separate DerivedData directories and records the tested revision.

```sh
bash Scripts/verify-apple-candidate.sh "$TFK_SIMULATOR_UDID" .build/candidate-check
```

Use a new output directory for each run. Add `--ui-test TinfoilKitUITests/ClassName/testName` for each selected UI test after seeding its fixtures on that simulator. Add `--device "$TFK_IPHONE_ID" --team "$TFK_TEAM_ID"` for a signed build with the Mac’s existing signing configuration, and `--install` to install it after verification. Add `--lightweight` to build and measure the unsigned lightweight release. Keep run outputs local since build logs can include device and signing identifiers.

Run the `ZIMArchive` scheme on a dedicated simulator for library and search tests. For the `TinfoilKit` UI test scheme, install the debug app in a dedicated simulator and copy `.build/fixtures/climate.zim` into its Documents folder as `Climate Test.zim`. The test uses the Files picker to import it on a fresh install.

For offline web archive navigation, install **Ready.gov Preparedness Guides** individually from Content Packs on a dedicated simulator or iPhone. Run `MapTileTests/HouseholdPrintingTests/testInstalledReadyGovEditionOpensAndPrintsThePowerOutageGuide` with that simulator’s installed data. With Wi-Fi off in Airplane Mode on iPhone, cold-launch the app and open the home page, Power Outages, Earthquakes, and Be Informed. Open a paginated collection and follow a link that redirects to a different archived directory. Confirm relative links, anchors, back navigation, and bookmarks reopen the expected pages. In Household, preview both printed pages of the Power outages guide. [Ready.gov edition metadata](https://download.kiwix.org/zim/zimit/ready.gov_en_all_2026-10.zim.meta4)

For the nearby-service Ask UI test, build an index from `Tests/RegionalPlaceIndexFixture/places.osm` with `Scripts/build-regional-place-index.py`. Import it from Files using **Map → + → Import regional place data** on the dedicated simulator and set Home at latitude 47.610, longitude −122.330. The synthetic fixture should resolve to Central Hospital.

For the regional bundle import UI test, copy a valid synthetic bundle folder named `Synthetic Regional Fixture` into the app’s Documents folder on the dedicated simulator. Set the dataset region to `Routing test fixture` when preparing the bundle. The test imports and removes that edition.

To exercise interrupted HTTPS downloads, use a dedicated simulator that trusts a test certificate for `127.0.0.1`. Run `python3 Tests/RegionalDownloadFixture/serve.py BUNDLE CERTIFICATE KEY CONFIGURATION` with the synthetic bundle and its test server certificate and key. Copy the generated configuration into the app’s Documents folder as `RegionalHTTPSFixture.json` and run `MapTileTests/RegionalBundleTransferTests/testResumesInterruptedHTTPSDownload`. Restart the server before each run.

For the version 2 UI test, run `python Tests/RegionalBundleFixture/run.py --ui-bundle ".build/Synthetic Regional Map Fixture"` and copy that folder into the same simulator Documents folder. The test verifies automatic basemap selection, visible publisher credit, and removal.

For the regional download recovery UI test, copy the same version 2 fixture into the test app’s `Library/Application Support/PendingRegionalDownload` directory on the simulator. Write `job.json` alongside the assets with `schemaVersion` set to `1`, `manifestSHA256` set to the SHA-256 of `manifest.json`, `cellular` set to `false`, and `started` set to `true`. The test reopens and installs the completed job without reaching a publisher.

For the named catalog download UI test, serve the version 2 fixture with a fresh `Tests/RegionalDownloadFixture/serve.py` process and a loopback certificate trusted by the dedicated simulator. Use a clean install with no pending download or installed copy of the synthetic bundle. Pass the generated JSON to the test runner as `TEST_RUNNER_TINFOILKIT_REGIONAL_CATALOG_FIXTURE="$(cat /path/to/RegionalHTTPSFixture.json)"` and run `TinfoilKitUITests/LibraryAndMapsTests/testNamedRegionalCatalogDownloadResumesAfterRelaunch`. The debug-only catalog entry reviews the verified manifest, then resumes and installs the bundle after the server drops the first asset transfer. After another cold launch with tile downloads disabled, the test looks up a street address and the nearest pharmacy, calculates walking and driving routes, and opens the route steps for each.

Run `bash Tests/NearbyPublicFixture/run.sh` on a Mac with local networking access to exercise discovery, opt-in, relay, and completion of existing transfers after discovery stops.

Project source code is under the [MIT license](LICENSE). See the [third-party notices](THIRD-PARTY.md) for dependency and content terms and the [implementation plan](PLAN.md) for milestones and release criteria.
