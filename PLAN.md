# Tinfoil Kit for iOS implementation plan

Build a standalone iPhone app that opens its installed library and maps after a cold launch with no network or desktop host. Use a SwiftUI shell and keep downloadable assets separate from household data. Exclude downloaded archives, indexes, map data and the tile cache from device backup. Include household notes, home and pins in backup.

## Status

Status as of 2026-11-24. "Built" means the feature exists in the app. It is complete only after its acceptance checks pass on a simulator and on an iPhone.

| Area | Status | Remaining |
| --- | --- | --- |
| Offline library | Built | Run the milestone 1 acceptance checks on a device with a publisher archive. Measure PDF extraction time and search-index storage on the larger packs. |
| Content packs | Partly built | The bundled catalog has English and Spanish choices and dated editions. Wi-Fi downloads, disk space checks, checksum verification, repair and replacement after indexing are implemented. Expand coverage, add catalog refresh and exercise real interrupted transfers. |
| Maps | Partly built | Imported basemaps, place indexes and Valhalla routing packs work offline. Add in-app regional downloads and verify the full navigation workflow on an iPhone. |
| Ask | Partly built | Search and cited answers use Apple's on-device model. Behavior on devices without Apple Intelligence and the decision on a downloadable model remain. |
| Household tools | Built | Run the airplane-mode restart and printing checks on a device. |
| Household sharing | Partly built | A Desktop kit screen and a phone-hosted read-only household session exist. Review the listener and test peer connectivity. Verified pack transfer and shared queries remain. |
| Setup, help and readiness | Partly built | Offline readiness and help exist. Portable setup remains. |

## Product roadmap

Use four functions to organize the work. Keep the existing Library, Map, Ask, Household, and Nearby entry points while testing whether users can find the next action while preparing, responding, or recovering.

| Function | Existing starting point | Next workflows |
| --- | --- | --- |
| Know | Installed library, map and routing packs, and Ask with local citations. | Show short, sourced hazard action cards. Find emergency facilities by capability and distinguish their designated purpose from confirmed availability. Add an offline readiness check that actually exercises reading, routing, documents, and on-device answers. |
| Monitor | Cloud candidates cache NWS state and territory alerts and Seattle text forecasts, and show WSDOT Puget Sound closures near a route. Apple verification is pending. | Build a dated incident timeline with official alerts, corrections, closures, and observations. Present a regional summary independently of Ask. [NWS forecast and alerts](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/nws-forecast) · [WSDOT advisories](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/wsdot-route-advisories) |
| Prepare | Household home, pins, notes, printable essentials, and explicit file backup. | Calculate household resource runway and identify the first limiting resource. Start with water, food, fuel, power, and medication inventory using household-entered quantities and consumption. Add welfare plans, drills, and local recovery records for damage, photos, losses, and expenses. |
| Connect | Expiring local browser shares, Nearby discovery, and a verified public worksheet. | Give browser guests selected incident summaries and references, then receive structured needs, offers, and observations for host review. Add a queue for information requests and later delivery over supported links. [Nearby and browser delivery plan](DISASTER-SHARING.md) |

### Work order and release gates

This order reconciles the updated survey with the default-branch implementation at `c122b2c` and the separately pushed cloud work. Run the existing Apple handoff in parallel whenever the Mac and iPhones are available. Verify the release candidates independently through `develop` and `main`, including cold offline reading and routing, publisher recovery, Nearby on two phones, and browser reconnect and revocation. Treat Linux fixtures as evidence for the paths they exercise. [Cloud handoff](https://github.com/scottleibrand/TinFoilKit-iOS/blob/codex/cloud-parity-handoff/CLOUD-HANDOFF.md)

**Release priority.** Start with offline reading and pack installation, then offline navigation and cited Ask, then Nearby and browser sharing. The Mac verification order below governs which candidates move through `develop` and `main`.

**Regional pilot.** Seattle is the first real-data test of the reusable regional pack format. Use local fixtures to verify installation, address and service search, and walking and driving while the Seattle edition awaits hosting. NWS state and territory alerts can be verified independently of the Seattle forecast and Puget Sound road sources.

The following work extends the parity candidates. The regional pilot can proceed alongside the release queue.

| Order | Increment and why it comes here | Acceptance or dependency |
| --- | --- | --- |
| 1 | **Finish the Monitor slice already in progress.** Start verification with nationwide NWS alerts and reconnect, then exercise the forecast and WSDOT branches with regional fixtures. Build the incident model from these concrete feeds. | Offline relaunch and intermittent reconnect pass. Preserve source identity and time, coverage, revision, correction and expiry. Present stale, missing and confirmed states distinctly. Closures stay advisory until they can be matched to routing edges and travel direction. Use FEMA lifelines to expose coverage gaps. [FEMA Community Lifelines](https://www.fema.gov/emergency-managers/practitioners/lifelines) |
| Parallel regional pilot | **Qualify reusable regional data.** Evaluate HDX discovery and HOT feature definitions against the existing pilot bundle. Prefer an authoritative dataset that adds missing facility information, such as community hubs or utility service areas. | Pin the resource and edition, verify original data rights and attribution, measure useful rows and bytes after clipping, and compare with the existing OSM index. Reuse the current Python builder and Swift reader where they fit. Publish each edition after its own bundle checks. |
| 2 | **Extend the trusted catalog and Nearby transfer.** Generalize from the pinned worksheet and checkpointed public transfer to one additional versioned public item. | Verify exact edition, redistribution permission, authenticated publisher digest, coverage and expiry. Test mixed-version peers, interrupted transfers, rejection of old revisions, and corrections or cancellations for the first eligible dynamic item. [Nearby recovery branch](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/nearby-public-transfer-recovery) |
| 3 | **Add deferred Online Ask.** Reuse the existing provider clients, Keychain credentials, answer cache, and saved-source cache. Begin with requests from the person using the device. | User reviews the question, provider, and data to send. Persist priority, retry, cancellation and result, with credentials referenced through Keychain. Reopen the request after relaunch and resume on an allowed connection. Offer an offline result with source provenance within the provider’s storage rules. Research on behalf of peers comes after explicit consent and delivery checks. |
| 4 | **Expand the foreground browser share.** Reuse the household listener and the branch with guest search, QR access, and reviewed note proposals. | Serve a small allowlist of eligible public references and dated updates on a phone. Verify token replacement, expiry, reconnect, and offline browsing on a second device. Treat guest observations as drafts with time, coarse area, and attributed source for host review. [Household sharing branch](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/household-guest-note-proposals) |
| 5 | **Add structured inventory and resource runway.** Start with deterministic calculations from a household’s own quantities and consumption. | Test unknown inputs, mixed units, the first limiting resource, backup and restore, and printing selected fields. Pair this with readiness checks that actually open a reference, find a place, and calculate an offline route. |

The Seattle qualification measured regional editions. The utility service-area prototype accepts an exact pinned local import while its redistribution terms are investigated. Continue the rights and publication checks before shipping a regional edition. [Seattle data pilot](Scripts/routing/SEATTLE-DATA-PILOT.md) · [Water service areas](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/local-water-service-areas)

The guided regional setup candidate adds named choices to the existing verified downloader and shows coverage, size, and rights at review. The first loopback fixture exercises the named path. Shipping a built-in Seattle choice requires an authorized versioned HTTPS host, the final manifest digest, and device verification. [Desktop first-time setup](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/GUIDE.md#first-time-setup) · [Seattle candidate edition](https://github.com/scottleibrand/TinFoilKit-iOS/blob/codex/regional-data-candidate/Scripts/routing/SEATTLE-CANDIDATE.md) · [Guided regional setup](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/guided-regional-setup)

Seattle release staging verifies the 318,339,726 installable bytes, retains the exact BBBike extract and data notice, and prints the manifest URL and pin for the chosen host. The real edition passed local staging with a test URL. Once a versioned HTTPS host is authorized, stage it for that URL, check the served manifest and byte ranges, then wire the final pin into guided setup for the iPhone acceptance run. [Seattle release staging](https://github.com/scottleibrand/TinFoilKit-iOS/blob/codex/seattle-regional-release/Scripts/routing/README.md#stage-an-edition-for-publication)

The first combined Monitor candidate brings the existing alert, Seattle forecast, and WSDOT branches into one Updates view. Its timeline uses saved source reports, preserves their dates, and identifies explicitly reported NWS updates and cancellations. Test offline relaunch and partial refresh on iPhone before adding more sources or retaining a longer incident history. [Combined Monitor candidate](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/monitor-regional-status)

The reconnect candidate clears the retry delay of unfinished checks when the connection drops or becomes disallowed. A completed check keeps its cooldown, and saved results survive cancellation. Exercise a short Wi-Fi outage, metered opt-in and opt-out, and saved NWS alerts for a state outside Washington on an iPhone. [Monitor reconnect candidate](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/monitor-reconnect)

The first Nearby, deferred Ask, and browser candidates are on separate branches for Apple verification. Nearby adds a second pinned original MIT template. Deferred Ask queues approved requests from the device owner. Browser guests can search either explicitly selected template in a public-only household session. Dated browser updates still require the publisher, delivery rights, provenance, and freshness checks documented for public sharing. [Nearby catalog](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/nearby-public-catalog) · [Deferred Ask](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/deferred-online-ask) · [Public browser references](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/browser-public-references)

The first household runway candidate uses saved amounts and daily rates for water, food, fuel, electricity, and medication. It preserves desktop notes and places interchange and adds an opt-in to the printed household sheet. Verify the editor, native restore, and PDF on iOS. [Household resource runway](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/household-resource-runway)

The functional readiness candidate opens sample HTML and PDF content and a matching citation, searches installed place data, and calculates walking and driving routes from a pair of local coordinates. Its on-device model check uses a built-in passage. Verify the full workflow on a phone in Airplane Mode with Wi-Fi off, including manual basemap rendering at the intended area and zoom. [Functional offline readiness](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/functional-offline-readiness)

Keep contextual action cards, drills, local recovery records, and optional gateway and radio interoperability on the roadmap. The first recovery packet can reuse the local journal and household print/export path for damage, photos, expenses and assistance guidance. Meshtastic is a candidate for compact message interoperability after the existing delivery workflow passes device tests. Add a runtime library only when a concrete requirement warrants it, with a versioned license and compatibility review. [FEMA disaster assistance](https://www.disasterassistance.gov/)

### Regional pipeline reuse decision

The Seattle qualification records verified source editions, measured regional sizes, offline comparisons with the existing bundle, and release terms. Use it to choose the first dataset before changing the regional format. [Seattle data pilot](Scripts/routing/SEATTLE-DATA-PILOT.md)

- The MIT-licensed `hdx-python-api` 6.8.0 wheel requires Python 3.11 or later. The official HDX `package_show` endpoint already supplies the metadata needed for this pilot. Use it for discovery and keep the existing regional builder’s runtime requirements. Revisit the client if larger catalog work needs its facilities. Each dataset needs its own rights and attribution review. [HDX Python API](https://pypi.org/project/hdx-python-api/6.8.0/) · [US health facilities metadata](https://data.humdata.org/api/3/action/package_show?id=hotosm_usa_health_facilities)
- HOT’s pinned BSD-3-Clause Tag Tree is a lightweight reference for OSM feature definitions. Its separately AGPL-licensed Raw Data API has substantial overlap with the current extract workflow. The HDX/HOT US health facilities edition is ODbL and derived from OSM, so use it to compare coverage before bringing in a second OSM-derived copy. Treat mapped assembly points, shelters, wells, and drinking-water sources as distinct classifications. Designated purpose and recorded attributes are separate from availability or current potability. [HOT Tag Tree](https://github.com/hotosm/osm-export-tool/blob/6da076d0a9bc6e2734884b63f086d25803b5bba4/ui/app/utils/tagtree.csv) · [Tag Tree license](https://github.com/hotosm/osm-export-tool/blob/6da076d0a9bc6e2734884b63f086d25803b5bba4/LICENSE.md) · [Raw Data API license](https://github.com/hotosm/raw-data-api/blob/5e6026ee0a803416300b2cd3b2eea01b1331755f/LICENSE)
- HDX also identified a 15 KB NASA FIRMS satellite-detection sample under a public-domain designation. The direct CSV changes independently of the HDX catalog. Leave it with the future wildfire work, retain acquisition timestamps and NASA credit, and describe detections separately from fire perimeters or incident status. [HDX dataset](https://data.humdata.org/dataset/nasa-firms-active-fire-usa-contiguous-and-hawaii-modis) · [NASA attribution](https://www.earthdata.nasa.gov/data/projects/lance)

Regional packs can use authoritative operational datasets where that edition’s coverage, freshness, and redistribution terms are verified. Give community communications hubs, charging and connectivity sites, warming and cooling centers, distribution points, and recovery centers distinct categories. Record capabilities such as accessibility and pet accommodation separately from live status. Evaluate OCHA operational datasets, HDX, HOT extracts, and Seattle Emergency Hubs using the existing regional bundle pipeline before introducing new formats. Preparedness drill scenarios and external radio transports can reuse the same observation and queue records after the first slices pass device tests.

Measure incremental updates for large regional editions. Start with independent asset updates and verified reuse of unchanged assets. Any future delta needs an exact base edition, integrity checks for the reconstructed files, and an atomic fallback to the working edition.

The official Seattle city-center forecast returned 1,617 gzip bytes for the day/night forecast and 4,847 for hourly periods. Both returned HTTP 304 on matching `If-Modified-Since` requests. Start with forecast text and preserve period times, the publisher update, and the app’s check time separately. The USGS magnitude 2.5+ past-day feed returned 6,055 gzip bytes in the same probe. Retain event revisions and official event links. [NWS API](https://www.weather.gov/documentation/services-web-api) · [USGS GeoJSON feeds](https://earthquake.usgs.gov/earthquakes/feed/v1.0/geojson.php)

## Gaps found in code review

Review of the working tree on 2026-11-24. **Beta** items block the first beta. The others can follow it.

### Library and reader

- Verify that interrupted Files imports, map imports, pack installs and repairs recover correctly on an iPhone. Imports check storage, report progress and can be cancelled. Unreadable archive folders are reported separately from healthy archives.
- Measure PDF page indexing and search on the actual Essentials packs. Library merges hits by each archive's rank and supports partial-word searches.
- Library search refreshes as each archive commits more of its index. Titles outside the indexed portion remain unavailable until their batch finishes.
- The reader loads each resource fully into memory and refuses anything over 32 MiB, so large PDFs and videos fail. The scheme handler doesn't support byte ranges, so audio and video won't play. Stream large resources and answer range requests.
- JavaScript is off for every archive, which breaks interactive content such as collapsible sections. Decide per pack, and keep the network block in place.
- The PDF document list only appears for catalog packs marked as PDF collections. An imported PDF collection opens its main page instead. Listing the documents also scans every entry in the archive.
- Library can verify the embedded ZIM checksum of imported files and the publisher SHA-256 checksum of catalog packs. Verify both on a device.
- The reader has back and forward controls and find within articles and PDFs. Reading history and bookmarks persist, including PDF page and article section links.

### Content packs

- Complete English Wikipedia is available in text-only and illustrated editions. Both are individual downloads. Measure download recovery, index size, and cold offline search on a device with space for the actual archives.
- **Beta.** The bundled catalog has pinned publisher editions and requires an app release to update. Add a way to refresh it and expand language, size, and preset choices against the upstream kit.
- **Beta.** Add device acceptance checks for an interrupted edition update and for recovery after failed indexing. The old archive stays in the library until the new index is ready.
- **Beta.** Bulk pack downloads use Wi-Fi. Individual transfers can allow cellular data after size confirmation. Temporary connection failures retry on the original network policy, using resume data when iOS supplies it. Verify pause and resume on a physical phone and evaluate discretionary transfers for Download All.
- Each pack has one source URL. Fall back to another official mirror when it fails.
- A checksum failure deletes the whole download. Retry once before discarding it, and report which mirror served it.

### Maps

- **Beta.** The map keeps multiple imported basemaps, place indexes, and offline routing graphs. Address and service search and household printing use the installed place indexes. Routes use a graph that covers both endpoints. Map verifies and installs all three assets from Files or from an HTTPS manifest with a trusted checksum. Pending download checkpoints survive relaunch. Publish reviewed regional editions and surface them in an in-app catalog. [Regional bundle tool](Scripts/routing/README.md#regional-catalog-bundle)
- **Beta.** Map downloads explains that the tile host sees the areas requested. Users can limit downloads to Wi-Fi, turn them off, or clear saved tiles. Tiles remain available until cleared. `v4.pmtiles` is a moving build, so tiles from different builds can mix. Choose a production tile host and record which build each cached tile came from.
- [Scripts/prepare-map-assets.sh](Scripts/prepare-map-assets.sh) extracts Seattle from the long-lived Source Cooperative basemap. Check the style and regenerate the derived assets when the source's ETag changes.
- The map style is minimal and hand-written. It has no street names, house numbers or point-of-interest icons, and only English labels. Adopt the Protomaps basemaps style (BSD-3-Clause) with its fonts and icons.
- Region coverage is a bounding box. Show coverage as the region's actual outline where it isn't rectangular.
- Regional place indexes are excluded from device backup.
- Installed routing packs support walking and driving directions with individual steps. Verify each mode on a physical iPhone in airplane mode.

### Ask

- Apple's on-device model has safety guardrails that may refuse medical and emergency questions, and a refusal currently shows as a generic failure. Measure refusals on a question set drawn from the Essentials packs, and show the passages with a clear explanation when the model declines.
- Retrieval uses 64-word search snippets rather than article sections, and the stop-word list and prompts are English only.

### Household

- Household notes, home and pins can move through an iPhone backup file or the desktop kit's notes and places files. Verify Files import, export and damaged-data recovery on a device.
- Printable references depend on exact edition filenames and page numbers. A catalog update silently drops them. The post-disaster source isn't in the catalog. Check page ranges whenever the catalog changes an edition.

### Tests and build

- The pack download fixture cuts a real HTTP transfer and checks that URLSession requests the remaining bytes and reconstructs the original file. The regional place index fixture runs as a separate script.
- The UI tests need a fixture copied into the simulator by hand. Automate that, and run the unit and UI tests in CI.

## 1. Offline library

- Read ZIM archives through zimru, a clean-room MIT reader, using a small Rust bridge. [Scripts/prepare-zim-reader.sh](Scripts/prepare-zim-reader.sh) pins the revision. Review the dependency licenses, archive coverage and decompression limits again whenever the pin changes. [zimru](https://github.com/jasontitus/zimru)
- Import a single-file ZIM from Files into app-managed storage. Validate it before registering it. Display its title and size, and reopen it after relaunch. Serve articles, images, styles and internal links to an isolated WebKit reader from the archive.
- The current import check reserves twice the archive size plus 64 MiB. The full English Wikipedia editions therefore need about 105 GB free for the text edition and 255 GB for the illustrated edition. Measure actual index storage before choosing an import or indexing policy for those editions.
- Build a local SQLite FTS5 index over article titles and text. Track indexing progress, retain stable archive and entry identifiers, and keep reading available while the index builds. ZIM files embed a Xapian index, but Xapian is GPL, so build the app's own index instead of reading it. [SQLite FTS5](https://www.sqlite.org/fts5.html)
- The large-library candidate searches committed text and embedded title prefixes together. A smaller newly installed archive can go first while a larger one retains its progress. On iPhone, start with the 2.75 GB English Wikipedia Top edition without pictures. Test title lookup immediately after install, a body-only search as batches commit, interruption by a smaller pack, and completion after a cold relaunch. Record index size, elapsed time, and search responsiveness before testing the complete editions. [Large offline library search](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/large-offline-library-search)
- Measure index size relative to archive size and indexing time on a device for each catalog pack. Set an index storage budget from those measurements. Index only titles for archives above the budget, and let the user opt in to full-text indexing. Continue indexing in the background with a background processing task so large indexes don't need the app open.
- Accept the milestone when a user can import, search for a term found only in an article body, open the result with its images, and follow an internal link after an offline cold launch. Use small fixtures on an explicit simulator with isolated DerivedData, then verify with a representative publisher archive on an iPhone.

## 2. Content packs

- Use upstream's catalog and edition choices as inputs. Download each pack from its publisher or an official mirror such as download.kiwix.org, ftp.fau.de or dumps.wikimedia.org. Record version, bytes, digest, source and attribution for each supported asset, and verify the digest against the publisher's checksum.
- The consolidated candidate covers all six desktop starter archive families and verifies their publisher editions. It offers WikiMed and both complete English Wikipedia editions individually. Verify new PDF indexes, printable references, and interrupted publisher downloads on an iPhone. [Starter and health catalog](https://github.com/scottleibrand/TinFoilKit-iOS/blob/codex/verified-starter-and-health-packs/CATALOG-AUDIT.md)
- The optional Ready.gov candidate completes desktop priority-1 catalog coverage alongside the consolidated starter branch. The separate offline navigation candidate resolves stored query keys and canonical redirect targets before WebKit loads a page. Verify the home page, three preparedness links, pagination, redirected relative links, and the two-page power outage print preview in Airplane Mode on iPhone. [Ready.gov reader candidate](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/ready-gov-offline-reader) · [Offline archive navigation](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/offline-archive-navigation)
- The publisher download candidate searches Kiwix and uses the matching Metalink's exact bytes and SHA-256 for individual background downloads and Files imports. It saves the approved edition and network choice for recovery. Keep discovered archives outside bulk downloads and automatic sharing. On iPhone, select a publisher-only edition, interrupt its download while backgrounded, relaunch, resume on the same allowed network, and confirm verification and offline reading. [Direct publisher downloads](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/direct-publisher-downloads) · [Desktop catalog discovery](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/GUIDE.md#changing-whats-in-the-kit)
- Add resumable background downloads, free-space checks for staging and indexing, and verification before install. Retain the working edition until its replacement and index are ready. Exercise interrupted downloads, low storage and failed upgrades. [Upstream download design](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/docs/DESIGN.md#downloading)

## 3. Maps

- Render installed Protomaps regions in MapLibre with packaged style assets, visible attribution and GPS location. A region install covers an explicit area. Test an upstream PMTiles file and cold-launch with connectivity disabled.
- The tile cache saves tiles fetched from Source Cooperative as the user pans. It supplements installed regions and does not replace them. When offline, show areas outside installed regions and the cache as unavailable, and never wait on the network to draw the map.
- Add regional place search from a prebuilt SQLite place index. Verify search and coverage boundaries offline. [Upstream map design](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/docs/DESIGN.md#maps)
- The iOS app runs Valhalla (MIT) with regional `.tfkroute` graph packs. A simulator test verifies walking and driving maneuvers and a one-way detour. The bundled walking preview remains available for its covered area. Include compatible graphs when publishing regional downloads. [Routing engine and format](Scripts/routing/README.md)

## 4. Answers and sharing

- The cited Ask candidate adds Spanish query fallback and keeps displayed model output at a citation boundary. Saved web evidence needs matching source text. Generated answers and provider snippets remain available in saved results. Household notes require a fresh opt-in for the on-device answer. On iPhone, generate an answer in Airplane Mode from English and Spanish archives, tap references across books and PDF pages, check that the answer abstains with insufficient evidence, and repeat with the model off. [Cited offline Ask](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/offline-ask-cited-evidence)

- Ask uses Apple's on-device model on eligible iPhones with iOS 26 or later. With the model unavailable or turned off, the source-quotes candidate highlights up to two short matching excerpts and links each to its saved source. Ask continues to show matching passages for partial matches. [Model-free source quotes](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/offline-ask-source-quotes) [Upstream search and answer behavior](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/docs/DESIGN.md#the-kit-page)
- Add an Ask acceptance case for “How long does our water system keep working if there is a gridwide power outage?” Search for the combined water-service and power-loss question, with terms such as water utility, pumping, backup power, storage, and pressure. Rank passages that address the relationship ahead of unrelated outage reports or water systems. Test both during and after indexing.
- Water outage questions ask for a utility or service area when one is missing, prioritize matching saved references, and quote any directly supported duration with a citation. Add provider lookup when service-area boundaries are available, and test on a phone in airplane mode with dated utility sources.
- Ask answers explicit nearby-service questions from saved Home and installed regional place indexes. It shows straight-line distance and dataset attribution and opens the result in Map. Verify with a regional pack in airplane mode.
- The combined Ask directions candidate handles saved pins, coordinates, exact named places or street addresses, and nearest-service requests. Requests with no mode offer walking and driving. Verify the handoff into Map and both route modes with an installed graph and the phone in airplane mode. [Ask directions candidate](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/ask-map-directions)
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
| Setup, help and readiness | Yes | Make installed content, source, last refresh, available capabilities and recovery steps visible. Test portable library setup from Files or an attached drive in Airplane Mode. Review matching editions, stop between packs, reopen a completed pack, and retry after fixing a checksum error. Use the existing map and household import flows for regional bundles and private data. [Portable library import](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/portable-library-import) |
| Regional navigation | Bundles, search and routing | Install a named region with explicit coverage. In Airplane Mode, choose From and To independently using a saved pin, address, or pasted coordinates. Check Home as the default, swap endpoints, and follow individual walking and driving steps. Verify that endpoints in separate packs need a common graph. Check edge snapping, one-way streets and turn restrictions with offline fixtures. [Route planner](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/offline-route-planner) |
| Ask and local chat | Search only | Verify offline search and cited answers, and verify multi-turn Offline Chat on an Apple Intelligence device. On an iOS 27 device with an on-device vision model, attach a locally available photo in Airplane Mode, cancel a replacement, and ask a follow-up. Verify that text chat still works on iOS 26. Add an optional downloadable model and map questions with deterministic fallback. [Offline Chat photos](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/offline-chat-photo-preparation) |
| Household sharing | Foreground browser and Nearby candidates | On a disconnected local network, open the host’s selected snapshot, search it, and submit a note or pin for host approval. Test permissions for each kind, check that a pin appears only after approval, and verify link replacement, expiry, and a network change on two devices. Keep the sharing screen open on the host. Serve only content whose redistribution terms permit it. [Household guest pins](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/household-guest-pins) |

Use local fixtures and isolated simulator build directories. Check representative production data and install each completed fix or feature on the connected iPhone when available.

### Mac verification order

Start with the simulator app and reader suites and a signed build at the current `develop` tip. Use the Apple runner to record the commit, keep test results separate, and install on the selected iPhone when reachable. Add the candidate-specific device checks before promoting each feature through `develop` and `main`. The cloud verified the runner’s command selection with mocked Apple tools. [Mac verification runner](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/apple-candidate-verification)

| Work | Integration and device checks |
| --- | --- |
| Starter packs and offline reader | Start with the combined candidate. It reconciles the pinned starter catalog, WikiMed, the individual Ready.gov edition, and offline navigation. Verify print ranges, pagination, relative links after redirects, and interrupted publisher downloads on Apple hardware. [Starter library release candidate](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/starter-library-release) |
| Library setup and downloads | The Content Packs recovery candidate includes approved publisher downloads, verified offline folder installs, one clean checksum retry, and a pinned mirror for the current Spanish Wikipedia highlights edition. On iPhone, test a background interruption and relaunch, origin-to-mirror recovery without changing the network policy, and a second bad checksum that leaves any installed edition intact. Stop a Files batch, then confirm a Files-installed edition appears as installed in publisher results. Test large-library indexing on a representative edition. [Content Packs recovery candidate](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/content-pack-recovery) · [Large library search](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/large-offline-library-search) |
| Offline navigation and Ask | Use the combined navigation candidate to test a named regional install with the local HTTPS fixture. After an interrupted transfer and cold launch, look up the synthetic address and nearest pharmacy, then open walking and driving route steps. Also test offline Files installs while public hosting is pending. The combined Ask candidate includes offline directions, cited answers and model-free source quotes. In Airplane Mode, test an explicit route with the model off and an ambiguous question that falls back to the library. With the model off, open an exact source from its quote and check that a partial match only appears in Matching passages. With the model on, ask an ordinary reference question with household notes off and on and open a citation from the answer. [Offline navigation candidate](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/offline-navigation-release) · [Combined offline Ask](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/offline-ask-source-quotes) |
| Nearby and browser sharing | Verify the two-item Nearby catalog before the guest pin branch that includes it. Test direct exchange and LAN exchange on two devices. Browser acceptance covers the selected snapshot, search, reviewed submissions and link lifecycle. Download the selected Home and pins in Safari and import the GPX into a compatible offline map app. Verify the download stays unavailable in a public-reference-only session and becomes unavailable through the old link after replacement. Full guest maps, broader library queries and shared Ask remain in the desktop inventory. [Nearby catalog](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/nearby-public-catalog) · [Household browser candidate](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/household-browser-waypoints) |
