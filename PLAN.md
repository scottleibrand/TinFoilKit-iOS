# Tinfoil Kit for iOS implementation plan

Build a standalone iPhone app that opens its installed library and maps after a cold launch with no network or desktop host. Use a SwiftUI shell and keep downloadable assets separate from household data. Exclude downloaded archives, indexes, map data and the tile cache from device backup. Include household notes, home and pins in backup.

## Intermittent connectivity

Preload maps, routing graphs, a compact emergency library, and regional directories. Use short connections for official alerts and local conditions. Fetch specialized documents on demand, including public medication labels selected on the device. Leave additional large general-reference packs available as optional downloads.

| Priority | Work | Initial acceptance |
| --- | --- | --- |
| P0 | NWS active alerts first, then qualifying official all-hazards alerts | Conditional fetch after a connection returns. Keep publisher, coverage, issued and expiration times, and last successful check visible offline. A complete authoritative snapshot can remove corrected or cancelled alerts. FEMA IPAWS live access needs an agreement. The delayed archive is historical. |
| P1 | Washington closures and pass, bridge, and ferry restrictions. Add locally verified shelter, utility, and drinking-water updates as feeds become available. | Show dated restrictions alongside offline routes. Reroute only for current, directionally matched closures. Distinguish potential shelter facilities from confirmed open shelters. |
| P2 | NWS forecasts and observations, NOAA river forecasts, and USGS earthquake feeds | Cache small geographically selected records. Refresh forecasts about every three hours and river forecasts hourly when connected. Show last successful check and source timestamps offline. |
| P3 | NIFC fire locations and perimeters, plus regional hazard layers | Clip and simplify foreground geometry, preserve publisher time and attribution, and measure transfer sizes. Cache Washington DNR hazards in regional packs and refresh active fire data hourly when connected. |
| P4 | Washington DOH and CMS healthcare, utilities, AFDC charging and fueling, NOAA Weather Radio, FoodKeeper, and selected emergency references | Verify edition, coverage and redistribution rights. Preprocess static records for regional offline search. Keep household choices local when fetching an individual public document. |

Schedule independent transfers, with alerts taking priority over routine refreshes and requested material ahead of lower-priority feeds. Use conditional HTTP validators, payload limits, and retries that respect network policy. Ordinary IP access over Starlink can use the same client. Treat phone-native satellite access and background wakeups as separate device checks.

Start with direct publisher feeds. Before introducing a scheduled regional snapshot, measure transfer sizes and freshness on a short connection and verify redistribution terms and any credential requirements. A snapshot should retain per-source timestamps, coverage, stable identities, provenance, and corrections. Only relay public updates whose authenticity and redistribution rights can be verified. Never broadcast household medication choices, notes, or precise locations.

- A Washington NWS active-alert sample returned 31 alerts in 12,744 compressed bytes. Its 163,319-byte decoded payload contained area descriptions and zone references, with no geometries. Keep these alerts browsable by area. The Updates tab checks a user-selected state or territory in the foreground and retains the last good list. Verify reconnection, offline relaunch and metered policy on iPhone. [NWS API](https://www.weather.gov/documentation/services-web-api) · [NWS alerts guidance](https://www.weather.gov/documentation/services-web-alerts)
- Updates can show forecasts for saved Home after explicit opt-in. The app rounds the coordinates to two decimal places before resolving the nearest NWS forecast grid. Day/night and hourly records refresh independently, with a three-hour target and conditional revalidation using the saved grid endpoint. Verify offline reopening, automatic and manual refresh, and expired-period display on iPhone. [NWS forecast API](https://www.weather.gov/documentation/services-web-api)
- WSDOT has a public Road Closures GeoJSON layer for low-volume queries. Pilot dated closures as route advisories before matching affected road segments and travel directions. Confirm redistribution rights before adding these to a republished snapshot or peer transfer. [WSDOT closure layer](https://data.wsdot.wa.gov/arcgis/rest/services/TravelInformation/TravelInfoRoadAlerts/FeatureServer/2) · [Dataset terms](https://data.wsdot.wa.gov/arcgis/rest/services/TravelInformation/TravelInfoRoadAlerts/FeatureServer/info/iteminfo)
- Updates shows the last successful check and coverage for each source. Its saved report list uses publisher timestamps and puts undated reports last. Explicit NWS updates and cancellations link to their source records. An alert that drops out of the active feed has no cancellation record. A check runs alerts first, then enabled Washington closures and Home forecasts. Verify the combined view with Wi-Fi disabled, then reconnect and check each source’s saved timestamp.
- The NOAA river API returned seven gauges within the Seattle bundle bounds. Keep observed and forecast levels separate, preserve the contributing source for each gauge, and use NWS alerts for official flood warnings. [NOAA NWPS guide](https://www.weather.gov/media/owp/operations/nwps_user_guide.pdf)

## Status

Status as of 2026-11-24. "Built" means the feature exists in the app. It is complete only after its acceptance checks pass on a simulator and on an iPhone.

| Area | Status | Remaining |
| --- | --- | --- |
| Offline library | Built | Run the milestone 1 acceptance checks on a device with a publisher archive. Measure PDF extraction time and search-index storage on the larger packs. |
| Content packs | Partly built | The bundled catalog has English and Spanish choices and dated editions. Wi-Fi downloads, disk space checks, checksum verification, repair and replacement after indexing are implemented. Users can review and download newer matching Kiwix editions as in-place updates. Expand coverage and exercise real interrupted transfers. |
| Maps | Partly built | Imported basemaps, place indexes and Valhalla routing packs work offline. Resumable in-app downloads accept trusted manifests, and Map plans routes from separate endpoints. The catalog offers a verified Seattle area edition with a basemap, place index and routing graph. Verify a cold launch and both route modes on an iPhone. Add more reviewed regional editions. |
| Situational updates | Partly built | Cache NWS alerts for a selected state or territory, opt-in Home forecasts and Puget Sound closure reports. Verify foreground reconnection and offline relaunch on iPhone, then expand coverage. |
| Ask | Partly built | Ask searches installed articles and PDF pages, opens cited quotes without a model, and can hand local destinations to walking or driving directions from Home. Verify generated citations and the household-notes opt-in on an eligible iPhone. Deferred Online Ask saves approved questions for the original provider when an allowed connection returns. Verify the live provider flow on iPhone. Offline Chat supports local photo prompts with a vision-capable Apple model on iOS 27. Verify a photo response in airplane mode. A downloadable model remains open. |
| Household tools | Built | Household supplies support local inventory and estimates from entered usage. Verify offline restart and opt-in inventory printing on a device. |
| Household sharing | Partly built | A phone can share a selected household snapshot, verified templates, and optional directions with a guest browser. Guests can search, export the shared locations, and submit notes or pins for host review. Guests can ask for cited quotes from selected verified templates and Offline Starter chapters. Questions stay in the guest browser. Verify the workflow on a second device and extend shared queries to eligible installed references. Nearby can exchange two public templates and the verified MIT-licensed Offline Starter library pack. Extend exchange to more cleared editions and eligible saved web sources. |
| Setup, help and readiness | Partly built | Readiness reports installed bundle status and coverage at saved Home. Its functional checks can open installed articles and PDFs, find citable passages and places, calculate both route modes, and try an on-device answer with a sample passage. Content Packs can verify and install catalog editions from a local folder. Portable setup for other content remains. |

## Gaps found in code review

Review of the working tree on 2026-11-24. **Beta** items block the first beta. The others can follow it.

### Library and reader

- Verify that interrupted Files imports, map imports, pack installs and repairs recover correctly on an iPhone. Imports check storage, report progress and can be cancelled. Unreadable archive folders are reported separately from healthy archives.
- Measure PDF page indexing and search on the actual Essentials packs. Library merges hits by each archive’s rank and supports partial-word searches. Index version 3 adds page text for supported large PDFs. Earlier index versions stay searchable while the new index builds. Readiness and printable excerpts use the same large PDF loader, with SHA-256 and page checks for printing.
- Library search refreshes as each archive commits more of its index. Embedded article titles are searchable during indexing. Full-text results become available as batches commit.
- The WebKit reader streams uncompressed archive resources in bounded chunks, including byte ranges for media. The PDFKit viewer opens large uncompressed, XZ-compressed and Zstandard-compressed PDFs from a temporary file written in bounded chunks. The compressed path limits cluster sizes and decoder memory. Other compressed resources still use the 32 MiB buffered reader. Verify real audio and video playback and additional large PDF compression formats. Build the [large PDF fixture](Tests/LargePDFFixture/build.sh), place the uncompressed, `zstd` and `xz` variants in the dedicated simulator’s Documents as `large-offline-pdf.zim`, `large-offline-pdf-zstd.zim` and `large-offline-pdf-xz.zim`, and run `ArchiveReadRangeTests` to verify PDFKit can read its text and release the temporary file.
- JavaScript is off for every archive, which breaks interactive content such as collapsible sections. Decide per pack, and keep the network block in place.
- PDF catalog collections and imports without a readable landing page open the document list. Other archives offer a PDF documents button. Document listing scans entry metadata only when opened and cancels when left.
- Library can verify the embedded ZIM checksum of imported files and the publisher SHA-256 checksum of catalog packs. Verify both on a device.
- The reader has back and forward controls and find within articles and PDFs. Reading history and bookmarks persist, including PDF page and article section links.

### Content packs

- Complete English Wikipedia is available in text-only and illustrated editions. Both are individual downloads. Measure download recovery, index size, and cold offline search on a device with space for the actual archives.
- **Beta.** Catalog pack rows can check Kiwix for newer editions with the same filename series and content variant. After review, a matching update targets the installed archive and preserves it through download, verification, and replacement indexing. Refreshing bundled defaults and expanding language, size, and preset choices remain open.
- **Beta.** Add device acceptance checks for an interrupted edition update and for recovery after failed indexing. The old archive stays in the library until the new index is ready.
- **Beta.** Bulk pack downloads use Wi-Fi. Individual transfers can allow cellular data after size confirmation. Temporary connection failures retry on the original network policy, using resume data when iOS supplies it. Verify pause and resume on a physical phone and evaluate discretionary transfers for Download All.
- Editions with a verified fallback mirror retry on that mirror after eligible origin failures. Checksum failures get one clean retry. Reviewed Kiwix downloads can also be repaired in place over Wi-Fi with exact size and SHA-256 verification. Verify publisher recovery and installed-edition preservation on a device.

### Maps

- **Beta.** The map keeps multiple imported basemaps, place indexes, and offline routing graphs. Address and service search and household printing use the installed place indexes. Routes use a graph that covers both endpoints. Map verifies and installs all three assets from Files or from an HTTPS manifest with a trusted checksum. Pending download checkpoints survive relaunch. The first named edition is available through the catalog. Verify it on an iPhone and publish editions for more regions. [Published edition](https://github.com/scottleibrand/TinFoilKit-iOS/releases/tag/region-seattle-2026-11-21) · [Regional bundle tool](Scripts/routing/README.md#regional-catalog-bundle)
- **Beta.** Map downloads explains that the tile host sees the areas requested. Users can limit downloads to Wi-Fi, turn them off, or clear saved tiles. Tiles remain available until cleared. New tile downloads require a pinned Source Cooperative object version and ETag. The app keeps tiles saved before the pin, whose editions were unrecorded.
- [Scripts/prepare-map-assets.sh](Scripts/prepare-map-assets.sh) extracts Seattle from the same pinned basemap. Reverify the style and decide how to track cache editions before updating the pin.
- The offline map labels streets, address points and selected services when the local tiles provide those names. Labels prefer the device language when available. Point-of-interest icons and a broader Protomaps style remain open.
- Region coverage is a bounding box. Show coverage as the region's actual outline where it isn't rectangular.
- Regional place indexes are excluded from device backup.
- Installed routing packs support walking and driving directions with individual steps. Verify each mode on a physical iPhone in airplane mode.
- Map can cache WSDOT’s reported Puget Sound closures after opt-in and flag a closure near an offline route. Verify overlay restoration after a style reload, bounded reconnect updates, source freshness, and offline reopening on iPhone. A proximity match provides an advisory. Matching closures to graph edges and travel directions is a separate milestone. [WSDOT Road Closures](https://data.wsdot.wa.gov/arcgis/rest/services/TravelInformation/TravelInfoRoadAlerts/FeatureServer/2)

### Ask

- Ask shows matching quotes if the model fails or the retrieved passages do not support a generated answer. Measure on-device responses to a question set drawn from the Essentials packs, including medical and emergency references.
- Retrieval uses 64-word search snippets. English and Spanish questions have offline keyword fallbacks. Verify that Apple Intelligence answers in the question’s language and cites the retrieved passages on an eligible iPhone.

### Household

- Household notes, home and pins can move through an iPhone backup file or the desktop kit's notes and places files. Roundtrips preserve desktop pin IDs and saved Home zoom. Importing the same Home location also keeps its iPhone note. Verify Files import, export and damaged-data recovery on a device.
- Printable references match verified catalog installations by the exact archive edition filename. Recheck paths and page ranges whenever a catalog edition changes. [Print reference definitions](Sources/TinfoilKit/HouseholdPrinting.swift)

#### Print reference checks

On November 24, 2026, bounded HTTP 206 reads located all nine configured PDF paths in the five publisher archives. The largest stored cluster was 6,269,263 bytes. The extracted PDFs were unencrypted and below the reader's resource size limit. `pdfinfo` and `pdftotext` confirmed the subjects and ranges below. The checks used the original PDFs' one-based page positions, which the app converts to zero-based PDFKit indexes. [Water 2024-08](https://download.kiwix.org/zim/other/zimgit-water_en_2024-08.zim.meta4) · [Field medicine 2024-08](https://download.kiwix.org/zim/other/zimgit-medicine_en_2024-08.zim.meta4) · [Post-disaster 2024-05](https://download.kiwix.org/zim/other/zimgit-post-disaster_en_2024-05.zim.meta4) · [Military medicine 2026-10](https://download.kiwix.org/zim/zimit/irp.fas.org_en_military-medicine_2026-10.zim.meta4) · [Ready.gov 2026-10](https://download.kiwix.org/zim/zimit/ready.gov_en_all_2026-10.zim.meta4)

| Excerpt | PDF pages | Printed labels | Preview pages |
| --- | --- | --- | ---: |
| Safe drinking water | 1–2 | Unnumbered | 2 |
| Emergency first aid | 124–129 | 77–82 | 6 |
| Diarrhea and dehydration | 198–199 | 151–152 | 2 |
| Power outages | 1–2 | Unnumbered | 2 |
| Burns and broken bones | 143–147 | 96–100 | 5 |
| Tourniquets for severe bleeding | 45–49 | 2-25 to 2-29 | 5 |

The post-disaster copies of the water guide, *Where There Is No Doctor* and FM 4-25.11 matched their primary PDF digests byte for byte. The separate military-medicine copy of FM 4-25.11 has a different digest and matched the same excerpt topic and page labels. Both Ready.gov paths point to byte-identical two-page FEMA handouts.

For the Apple check, use a dedicated simulator or test phone. Install Water Treatment and Field Medicine from Content Packs with publisher checksum verification. In a build that includes the desktop starter packs, check the fallbacks with an isolated library containing only Post-Disaster, then only Military Medicine. After an airplane-mode restart, open each expected preview and compare its first and last pages and page count to the table. Check the system print preview for the excerpt and household sheet.

The optional Ready.gov download uses the pinned October 2026 edition. Verify the home page, Power Outages, Earthquakes, and Be Informed in WebKit in Airplane Mode. Follow a link with a pagination query, then test relative links after a cross-directory redirect. Confirm the two-page Power outages preview under Print the Essentials. The installed archive must carry the catalog edition metadata for this preview. [Ready.gov publisher manifest](https://download.kiwix.org/zim/zimit/ready.gov_en_all_2026-10.zim.meta4)

### Tests and build

- The pack download fixture cuts a real HTTP transfer and checks that URLSession requests the remaining bytes and reconstructs the original file. The regional place index fixture runs as a separate script.
- Pull requests to main run app and reader unit suites, household persistence, and offline readiness on a hosted iPhone simulator. The Files import test still uses a manually staged fixture on a dedicated simulator. [CI rollout](https://github.com/scottleibrand/TinFoilKit-iOS/pull/45)

## 1. Offline library

- Read ZIM archives through zimru, a clean-room MIT reader, using a small Rust bridge. [Scripts/prepare-zim-reader.sh](Scripts/prepare-zim-reader.sh) pins the revision. Review the dependency licenses, archive coverage and decompression limits again whenever the pin changes. [zimru](https://github.com/jasontitus/zimru)
- Import a single-file ZIM from Files into app-managed storage. Validate it before registering it. Display its title and size, and reopen it after relaunch. Serve articles, images, styles and internal links to an isolated WebKit reader from the archive.
- Before copying an import, check that the disk has room for the archive and its index. Imports need free space equal to the archive size during the copy. If that proves too restrictive for large archives, read them in place through security-scoped bookmarks.
- Build a local SQLite FTS5 index over article titles and text. Track indexing progress, retain stable archive and entry identifiers, and keep reading available while the index builds. ZIM files embed a Xapian index, but Xapian is GPL, so build the app's own index instead of reading it. [SQLite FTS5](https://www.sqlite.org/fts5.html)
- Measure index size relative to archive size and indexing time on a device for each catalog pack. Set an index storage budget from those measurements. Index only titles for archives above the budget, and let the user opt in to full-text indexing. Use iOS background processing to continue indexing installed archives without a network connection. When a processing window expires, the queue can resume from the last committed batch. Verify system delivery and expiration on a physical iPhone.
- Accept the milestone when a user can import, search for a term found only in an article body, open the result with its images, and follow an internal link after an offline cold launch. Use small fixtures on an explicit simulator with isolated DerivedData, then verify with a representative publisher archive on an iPhone.

## 2. Content packs

- Use upstream's catalog and edition choices as inputs. Download each pack from its publisher or an official mirror such as download.kiwix.org, ftp.fau.de or dumps.wikimedia.org. Record version, bytes, digest, source and attribution for each supported asset, and verify the digest against the publisher's checksum.
- Add resumable background downloads, free-space checks for staging and indexing, and verification before install. Retain the working edition until its replacement and index are ready. Exercise interrupted downloads, low storage and failed upgrades. [Upstream download design](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/docs/DESIGN.md#downloading)

## 3. Maps

- Render installed Protomaps regions in MapLibre with packaged style assets, visible attribution and GPS location. A region install covers an explicit area. Test an upstream PMTiles file and cold-launch with connectivity disabled.
- The tile cache saves tiles fetched from Source Cooperative as the user pans. It supplements installed regions and does not replace them. When offline, show areas outside installed regions and the cache as unavailable, and never wait on the network to draw the map.
- Add regional place search from a prebuilt SQLite place index. Verify search and coverage boundaries offline. [Upstream map design](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/docs/DESIGN.md#maps)
- The iOS app runs Valhalla (MIT) with regional `.tfkroute` graph packs. A simulator test verifies walking and driving maneuvers and a one-way detour. The bundled walking preview remains available for its covered area. Include compatible graphs when publishing regional downloads. [Routing engine and format](Scripts/routing/README.md)

## 4. Answers and sharing

- Ask uses Apple's on-device model when Apple Intelligence is available, which requires an iPhone 15 Pro or newer on iOS 26. Other devices get passage search only. Retrieve passages through library search, link answers to exact articles, and show the retrieved passages when evidence is insufficient. [Upstream search and answer behavior](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/docs/DESIGN.md#the-kit-page)
- Add an Ask acceptance case for “How long does our water system keep working if there is a gridwide power outage?” Search for the combined water-service and power-loss question, with terms such as water utility, pumping, backup power, storage, and pressure. Rank passages that address the relationship ahead of unrelated outage reports or water systems. Test both during and after indexing.
- Water outage questions ask for a utility or service area when one is missing, prioritize matching saved references, and quote any directly supported duration with a citation. Add provider lookup when service-area boundaries are available, and test on a phone in airplane mode with dated utility sources.
- Ask answers explicit nearby-service questions from saved Home and installed regional place indexes. It shows straight-line distance and dataset attribution and opens the result in Map. Verify with a regional pack in airplane mode.
- Decide whether to offer a downloadable model, such as llama.cpp with a small upstream model, for devices without Apple Intelligence. Decide after measuring memory, latency and thermals on the oldest device it would support. Show each model's license and usage policy before download, including Thinking Machines' acceptable use policy for Inkling.
- Household sharing is covered in the parity table below.

## Release decisions

The first beta covers the offline library, pack management, one installed regional basemap, household tools, and setup and readiness. Aim for a starter configuration under 10 GB including indexes and routing data, subject to measuring actual packs. The minimum OS is iOS 17. Set the representative map region and supported devices from dependency and device tests before publishing the beta.

Distribute the app free, with no purchase or subscription in front of any content. Several packs, including iFixit, LibreTexts and Khan Academy, prohibit commercial use.

Original iOS work is MIT. Review exact dependency and distribution terms before shipping a GPL component. Use documented interfaces to independently deployed services where compatible, or implement the needed behavior independently. Content and model weights retain their own licenses. [Project licensing rules](AGENTS.md)

## Public repository release

- Publish with the current Tinfoil Kit name, adapted icon and bundle identifier. The owner will ask the upstream author whether to adopt this port or keep it as a separately branded fork. Revisit the branding before an App Store release.
- Verify the README's build and test instructions from a fresh clone, including Valhalla preparation. Reuse the tested long-lived Seattle basemap source.
- The household listener is scoped to the local link and requires a user-selected snapshot and an expiring link. The UI and README describe its unencrypted HTTP transport. Online Ask sends the question to the selected provider. Local library passages stay on the phone.
- Retain the notices and update them when dependencies or content change. [Third-party notices](THIRD-PARTY.md)

## Desktop feature parity

The [nearby disaster-sharing plan](DISASTER-SHARING.md) covers a lightweight install, automatic nearby exchange of verified public content, and explicit approval for private material.

Compare the iOS app to desktop revision `6417927`. Revisit the inventory as each milestone lands, including the desktop portal, command-line setup and maintenance, and the household sharing service. Use native iOS workflows for equivalent outcomes and track any outcome the platform cannot provide. [Desktop design](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/docs/DESIGN.md)

| Milestone | Beta | Verify on iOS |
| --- | --- | --- |
| Library and content packs | Yes | Select a preset, language and edition. Install and search curated packs and larger archives. Check sizes, attribution and available storage. Verify, repair, update and remove packs while keeping valid content available. Exercise full-text search on PDF collections and confirm offline reading after restart. |
| Household tools | Yes | Save home, pins and notes, then restart in airplane mode. Find pins by name, copy decimal and DMS coordinates, and print the household essentials and verified page ranges from the installed editions. |
| Setup, help and readiness | Yes | Make installed content, source, last refresh, available capabilities and recovery steps visible. Provide offline help and a portable setup workflow for permitted content. |
| Regional navigation | Basemap only | Install a named region with explicit coverage. Find street addresses and nearby services, search with coordinates, and follow selectable walking and driving steps. Check edge snapping, one-way streets and turn restrictions with offline fixtures. |
| Ask and local chat | Search only | Verify offline search and cited answers, and verify multi-turn Offline Chat on an Apple Intelligence device. Add an optional downloadable model and map questions with deterministic fallback. |
| Household sharing | No | Start after pack installation is reliable. First transfer a single verified pack between two nearby phones, then add a phone-hosted session with shared queries. Declare local network and Bonjour usage. iOS suspends the host when the app leaves the foreground, so state that the host phone keeps the app open and test reconnecting after interruptions. Verify access rules and notes conflicts on two real devices. Serve only content whose redistribution terms permit it. Evaluate a desktop companion that talks to the existing LAN service separately. |

The Ready.gov English 2026-10 archive remains a catalog candidate. Kiwix lists it as an open-access archive with matching SHA-256 sidecars. A one-byte HTTP 206 response confirmed 2,063,895,408 total bytes. The archived home page links to `power-outages`, `earthquakes` and `be-informed`. The ZIM contains their `www.ready.gov/`-prefixed paths as HTML entries and the Household Printing PDF at `www.ready.gov/sites/default/files/2024-08/ready.gov_power-outage_info-sheet.pdf`. The home page is stored as `www.ready.gov/`, with no slashless entry. Foundation's `URL.path` returns `/www.ready.gov` for `zim://archive/www.ready.gov/`, so the current reader loses the trailing slash at lookup. Before adding this edition, preserve the exact archived path and verify offline home, article navigation and printing on iOS. Individual files retain their source terms. [Kiwix edition metadata](https://download.kiwix.org/zim/zimit/ready.gov_en_all_2026-10.zim.meta4) · [Example publisher terms](https://www.ready.gov/sites/default/files/2020-03/ready_emergency-financial-first-aid-toolkit.pdf)

Use local fixtures and isolated simulator build directories. Check representative production data and install each completed fix or feature on the connected iPhone when available.
