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
| Monitor | State and territory NWS alerts are implemented on the cloud branch. Washington road closure advisories and other direct feeds follow the intermittent-connectivity plan. | Build a dated incident timeline with official alerts, corrections, closures, and observations. Present a regional summary independently of Ask. [NWS implementation and sync plan](https://github.com/scottleibrand/TinFoilKit-iOS/tree/codex/intermittent-nws-alerts) |
| Prepare | Household home, pins, notes, printable essentials, and explicit file backup. | Calculate household resource runway and identify the first limiting resource. Start with water, food, fuel, power, and medication inventory using household-entered quantities and consumption. Add welfare plans, drills, and local recovery records for damage, photos, losses, and expenses. |
| Connect | Expiring local browser shares, Nearby discovery, and a verified public worksheet. | Give browser guests selected incident summaries and references, then receive structured needs, offers, and observations for host review. Add a queue for information requests and later delivery over supported links. [Nearby and browser delivery plan](DISASTER-SHARING.md) |

### First implementation slices

1. Finish and verify cached NWS alerts, forecast, and Washington closures. Introduce the incident record as a second source lands. Retain the original source and stable upstream identity, event and observation times, geographic coverage, revision, and links to superseded or cancelled messages. Keep local observations distinct from official records, and make no-data, stale, expired, and confirmed states clear. Start with the transportation, water and weather information that has a verified feed. Use the Community Lifelines categories to guide future coverage without filling gaps with inferred status. [FEMA Community Lifelines](https://www.fema.gov/emergency-managers/practitioners/lifelines)
2. Add a local-only resource runway calculation and an airplane-mode readiness check. Let a household set its planning assumptions, see which quantity runs out first, and print selected fields with the existing essentials. Include unknown quantities, mixed units, a completely offline cold launch, and a partially installed pack in acceptance tests. Add sourced action cards after references and edition provenance are available.
3. Use the existing foreground phone host to serve selected incident and reference snapshots in a browser. Then admit structured observations and requests as reviewable drafts. Record what was observed, when, what area it applies to, and its source or confidence. Keep proposed observations separate from approved records. Consider an independent always-on gateway after the phone experience is verified.
4. Add a persistent queue for user-requested public manuals, official pages, and other targeted retrieval. First search locally, show what is unavailable or stale, and let the user review what will be sent. Persist queue state, priority, retry timing, cancellation, result, and source metadata. Report completion and keep an offline source copy when terms permit. Require explicit approval before sending a private question or attachment, choosing a cloud model for it, or asking a peer to fulfill it. Reuse the queue’s records across available network, Nearby and file transports.
5. Add a local incident journal and recovery export. Capture timestamped observations, inventories, photos, claims checklist items, losses and expenses. Keep source originals and let users choose what a printable packet or exported file contains. Link to dated official assistance guidance and distinguish designated recovery centers from confirmed openings. [FEMA disaster assistance](https://www.disasterassistance.gov/)

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
- Before copying an import, check that the disk has room for the archive and its index. Imports need free space equal to the archive size during the copy. If that proves too restrictive for large archives, read them in place through security-scoped bookmarks.
- Build a local SQLite FTS5 index over article titles and text. Track indexing progress, retain stable archive and entry identifiers, and keep reading available while the index builds. ZIM files embed a Xapian index, but Xapian is GPL, so build the app's own index instead of reading it. [SQLite FTS5](https://www.sqlite.org/fts5.html)
- Measure index size relative to archive size and indexing time on a device for each catalog pack. Set an index storage budget from those measurements. Index only titles for archives above the budget, and let the user opt in to full-text indexing. Continue indexing in the background with a background processing task so large indexes don't need the app open.
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

Use local fixtures and isolated simulator build directories. Check representative production data and install each completed fix or feature on the connected iPhone when available.
