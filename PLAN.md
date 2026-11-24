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

The desktop [user guide](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/GUIDE.md) describes the workflows used for this inventory. The iOS column reflects the source and documented workflows through PR #14 (`fd5aeab`). See the [cloud handoff](https://github.com/scottleibrand/TinFoilKit-iOS/blob/codex/cloud-parity-handoff/CLOUD-HANDOFF.md) for the Linux work and Apple verification plan.

| Desktop workflow | Available on iOS | Remaining parity work and verification |
| --- | --- | --- |
| Choose Essentials, a larger Wikipedia edition, and additional books. Preview, update, verify, repair and remove downloads. | Content Packs has bulk presets, language filters, imports, checksum verification, repair and edition updates. The Library searches indexed articles and PDFs. | Audit the desktop and iOS catalogs by edition, language, size, checksum and terms. Account for desktop catalog discovery and optional books. Confirm range support per publisher and verify physical background recovery. Check that working editions stay searchable across update failures and cold offline launches. |
| Save home, named pins and notes. Move household data with the kit. Print a household sheet and selected reference pages. | Household stores home, pins and notes, supports backup and desktop file exchange, and prints selected reference pages and nearby services when an index is installed. | Verify persistence, file round trips and nearest services on a phone in airplane mode. Recheck printable ranges whenever an edition changes. Verify printable output against installed content and test partially installed libraries. |
| Guided regional setup, update preview, status, offline help and self-test. Expand coverage with additional regions. | Offline readiness shows storage, content, indexing, model availability and map coverage. The starter guide and lightweight build work with separately installed data. | Provide a guided regional setup and portable permitted-content workflow. Show edition, source, coverage, last refresh and recovery actions at install and update time. Verify fresh offline launch and recovery with partially installed data. |
| Find addresses and nearby services and plan walking or driving routes using the installed region. | Map accepts decimal and DMS coordinates. Map can import a three-asset regional bundle from Files with a verified basemap, place index and routing graph. Standalone data imports remain available. The signed build was installed and a synthetic bundle passed simulator import, selection and removal checks. | Publish a discoverable dated region with validated hashes and attribution. Verify the in-app download path and recovery using a published edition. Verify boundary coverage, endpoints, one-way streets, turn restrictions and route steps on a cold offline launch. |
| Search the full library, answer from retrieved passages with citations, and use simple map questions without the model. | Ask searches installed references and eligible saved sources, streams Apple Intelligence answers when available, and shows matching passages and citations. Explicit nearby-service questions use saved Home and installed indexes. Results include distance and attribution and open in Map. | Verify the nearby-service flow in airplane mode. Extend it to explicit directions and named pins. Preserve the library search path for other questions and verify source navigation and model-off behavior. Review opt-in use of household context for local answers. |
| Select an offline model and chat across turns, including with photo attachments. | Offline Chat uses Apple Intelligence on supported devices and holds conversation state while open. | Verify multi-turn chat on a supported phone. Evaluate an optional downloadable model, photo input, supported devices, storage and license terms. |
| Share the kit on a local network. Guests use the library, maps and Ask, and edit shared notes with conflict handling. The host controls access and revocation. | A phone can host a time-limited read-only browser view of selected household information. Separate Nearby discovery can relay the verified check-in worksheet. | Extend the foreground phone-hosted session with permitted shared queries and explicit access and revocation. Verify conflicts before enabling shared edits. Test reconnecting, background suspension and consent on two devices. Desktop boot-time hosting depends on a continuously available host. Track Nearby exchange in [DISASTER-SHARING.md](DISASTER-SHARING.md). |

Cloud candidates awaiting Apple verification include the starter and complete Wikipedia catalogs, version 2 regional downloads from a trusted manifest, Ask directions to nearby services and saved pins, cross-archive PDF retrieval, household link replacement and worksheet access, and Nearby transfer recovery. The production regional catalog, guest queries, optional model evaluation and physical interruption checks remain open. [Cloud handoff](https://github.com/scottleibrand/TinFoilKit-iOS/blob/codex/cloud-parity-handoff/CLOUD-HANDOFF.md)

Use local fixtures and isolated simulator build directories. Check representative production data and install each completed fix or feature on the connected iPhone when available.
