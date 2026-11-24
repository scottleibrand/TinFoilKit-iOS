# Tinfoil Kit for iOS

This app is based on the original desktop Tinfoil Kit by Travis Bloom and Tudor City Ventures. [Desktop repository](https://github.com/tudor-city-ventures/tinfoil-kit) · [Official website](https://tinfoilkit.com/)

Read ZIM archives and view regional maps on an iPhone without an internet connection. The app includes full-text search for installed articles, a downloadable Essentials catalog, and a Seattle-area map with local place search. Large archives index in batches and resume after interruption when storage is available. Walking previews require the Seattle walking graph.

Download packs individually over Wi-Fi or choose Download Essentials or Download All to get current editions in bulk. Filter by language in Content Packs to find English and Spanish editions. The Extended Library includes a larger English Wikipedia selection and iFixit guides.

Press and hold an installed archive in Library to verify its checksum or remove it. Catalog packs use the publisher’s SHA-256 checksum. Files imports use the ZIM’s embedded checksum to check for corruption. Catalog packs also support repair and updates. Repair replaces a same-edition copy after checksum verification. An update keeps the earlier edition and its index available until the new one is verified and searchable.

Library and Ask can search article text and PDF pages as indexes build. Results from PDFs open to the matching page. Ask can stream a cited answer on devices with Apple Intelligence, and you can turn its on-device model off from the options menu.

In an open article, use the archive back and forward buttons to retrace followed links, and **Find on page** to search the current article. In a PDF, use **Find in document** to jump between matches. Both reader searches work offline.

Use **Add bookmark** in an article or PDF, then reopen it under **Library → Reading list**. The list also keeps recent reading and reopens PDFs on the page you were viewing. Clearing recent reading keeps your bookmarks.

When local evidence is insufficient, use **Ask online** and choose GPT, Claude, or Google Gemini. Add each provider’s API key under **Ask options → Online providers**. The app sends the question after you choose a provider and keeps API keys in the device’s Keychain. Future offline searches can use saved GPT or Claude answers, citation details, and readable source copies when available. Gemini grounding stays in the online session because Google restricts indexing and reuse of grounded responses and links. [Google grounding terms](https://ai.google.dev/gemini-api/terms#grounding-with-google-search)

The Map tab saves tiles as you pan, zoom, or follow your location. Saved tiles stay in the app’s durable storage and remain available across launches. Basemap tiles use the Protomaps archive hosted by Source Cooperative. Library indexing continues while you use the Map tab. [Protomaps OpenStreetMap data](https://source.coop/protomaps/openstreetmap)

In Map, press and hold a location to copy its coordinates, set it as home, or save a named pin. Map search accepts saved place names and coordinates in decimal or degrees, minutes, and seconds. The Household tab keeps notes, home, and pins on the device.

In **Household → Import and export**, save a household backup to Files or restore one on another iPhone. The same screen imports and exports the desktop kit’s `notes.txt` and `places.json` files individually. If the local household file is damaged, restoring a backup or starting a new household keeps a separate copy of the damaged file.

In **Household → Share on local network**, select the household details to share and start a browser session on a trusted Wi-Fi or Ethernet network with IPv4. The link uses unencrypted HTTP. Anyone on that network who has the link or can watch its traffic can read the selection. The session ends after ten minutes, when you leave the screen, or when you stop it.

Use Print the Essentials in Household for a printable copy of your household information and selected pages from installed references. Install a regional place index to include the nearest services to your saved home.

To build a regional address and service index, install `osmium==4.2.0` and run `python Scripts/build-regional-place-index.py region.osm.pbf region.sqlite --region "Region name" --source https://provider.example/region.osm.pbf`, using the actual source URL. Import the resulting SQLite file from Map. It works with any basemap and includes its own OpenStreetMap attribution.

Import a compatible `.tfkroute` graph from Map to plan offline walks and drives and follow individual route steps. Build a graph from a regional OSM extract with `python Scripts/build-regional-routing-pack.py --help`. Routing packs are separate from basemap tiles and place indexes. [Routing engine and graph formats](Scripts/routing/README.md)

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

Run the `ZIMArchive` scheme on a dedicated simulator for library and search tests. For the `TinfoilKit` UI test scheme, install the debug app in a dedicated simulator and copy `.build/fixtures/climate.zim` into its Documents folder as `Climate Test.zim`. The test uses the Files picker to import it on a fresh install.

Run `bash Tests/NearbyPublicFixture/run.sh` on a Mac with local networking access to exercise discovery, opt-in, relay, and completion of existing transfers after discovery stops.

Project source code is under the [MIT license](LICENSE). See the [third-party notices](THIRD-PARTY.md) for dependency and content terms and the [implementation plan](PLAN.md) for milestones and release criteria.
