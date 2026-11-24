# Tinfoil Kit for iOS

Read ZIM archives and view regional maps on an iPhone without an internet connection. The app includes full-text search for installed archives up to 1 GB, two downloadable Wikipedia packs, and a Seattle-area map with local place search. Walking previews require the Seattle walking graph. On compatible devices, the app can summarize matching passages with Apple Intelligence and link to the articles it cites.

## Build locally

Use Xcode, XcodeGen, Rust, Node.js, and Python 3. The first preparation downloads the pinned reader and map dependencies plus a public ZIM test fixture. Generated files and external data are stored in `.build/`.

```sh
rustup target add aarch64-apple-ios-sim
bash Scripts/prepare-map-assets.sh
bash Scripts/prepare-zim-reader.sh
xcodebuild build -project TinfoilKit.xcodeproj -scheme TinfoilKit \
    -destination 'platform=iOS Simulator,id=YOUR_SIMULATOR_UDID' \
    -derivedDataPath .build/AppDerivedData CODE_SIGNING_ALLOWED=NO
```

For a device build, add the Rust target `aarch64-apple-ios`, run `bash Scripts/prepare-zim-reader.sh device`, and select your development team and phone in Xcode.

To enable Seattle walking previews, download the Seattle PBF from BBBike, install `osmium==4.2.0` in a local Python environment, and run `python Scripts/build-walking-graph.py Seattle.osm.pbf .build/map-assets/seattle-walking.sqlite` before building. The walking graph and place database use OpenStreetMap data under ODbL 1.0. [BBBike Seattle extract](https://download.bbbike.org/osm/bbbike/Seattle/) · [OpenStreetMap attribution and license](https://www.openstreetmap.org/copyright)

## Test

Run the `ZIMArchive` scheme on a dedicated simulator for library and search tests. For the `TinfoilKit` UI test scheme, install the debug app in a dedicated simulator and copy `.build/fixtures/climate.zim` into its Documents folder as `Climate Test.zim`. The test uses the Files picker to import it on a fresh install.

Project source code is under the [MIT license](LICENSE). Third-party software and downloaded data retain their own terms. The [implementation plan](PLAN.md) describes the milestones and release criteria.
