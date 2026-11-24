# Cloud handoff

The goal is desktop feature parity for Tinfoil Kit on iOS. [PLAN.md](PLAN.md) tracks parity and [DISASTER-SHARING.md](DISASTER-SHARING.md) tracks nearby exchange. This handoff is for a Linux cloud session while the Mac and iPhone are offline.

## Start here

Fetch `origin` and check both `origin/develop` and `origin/main`. Both branches were synced at `d6e7caf` after PR #15. Recheck the branch tips and the work below before starting an overlapping change.

Use a fresh `codex/` feature branch from the current `origin/develop` for work awaiting Apple tests. Keep each feature in its own commits so it can move to `develop` after verification. Push the feature branch for the Mac session to retrieve. Open and merge one tested feature at a time through a `develop` → `main` PR.

The upstream desktop checkout and generated build inputs are ignored. For parity review, clone [the desktop repository](https://github.com/tudor-city-ventures/tinfoil-kit) into `upstream/tinfoil-kit` and check out `64179271bcebffc5d76f1e3d13d2592e0089b6b1`. Reuse the documented interfaces and behavior without copying copyleft code. Keep original code MIT and track dependencies, models and dataset rights in [THIRD-PARTY.md](THIRD-PARTY.md).

## Integrated work

- Pack recovery keeps the saved transfer's network policy. A loopback test verified recovery after two connection drops. A live publisher download interrupted while the iPhone app is backgrounded remains a device check. [PR #8](https://github.com/scottleibrand/TinFoilKit-iOS/pull/8)
- Ask finds the nearest requested service using saved Home and installed place data. The result opens in Tinfoil Kit Map or passes the destination coordinates to Google Maps. Synthetic lookup and both controls passed in the simulator. Keep the separate `codex/ask-nearby-intent` branch as a reference for wording coverage. [PR #9](https://github.com/scottleibrand/TinFoilKit-iOS/pull/9)
- The regional bundle builder produces a place index and routing pack from one pinned extract. The Valhalla ARM64 producer fixture passed, including rejection of corrupt artifacts and incompatible routing metadata. [PR #10](https://github.com/scottleibrand/TinFoilKit-iOS/pull/10)
- Map imports a version 1 regional bundle from Files and manages both assets as a single edition. The native Files import and removal test and 62 app unit tests passed. The signed iPhone build was installed. Basemaps are still imported separately. [PR #11](https://github.com/scottleibrand/TinFoilKit-iOS/pull/11)
- Both app profiles include the app and ZIMArchive privacy manifests required for distribution. All 62 simulator unit tests passed and the signed standard build was installed on the iPhone. The one-time TestFlight upload still needs a confirmed App Store Connect team and signing access on the Mac. [PR #12](https://github.com/scottleibrand/TinFoilKit-iOS/pull/12)
- Both profiles now supply version `1.0.0` and build `1` through shared build settings. The signed app's packaged version fields were verified and the build was installed on the iPhone. [PR #13](https://github.com/scottleibrand/TinFoilKit-iOS/pull/13)
- Version 2 bundles include a verified basemap with its own edition and publisher credit. The pinned producer built the fixture, the Files UI imported, selected, and removed it, and 65 app unit tests passed. The signed build was installed on the iPhone. [PR #14](https://github.com/scottleibrand/TinFoilKit-iOS/pull/14)
- Content Packs offers complete English Wikipedia in separate text-only and illustrated downloads. Publisher manifests and range probes confirmed both byte counts and checksums. All 66 app tests, 18 reader tests and the catalog UI test passed. The signed phone build succeeded, with installation pending when the phone is reachable. Full-archive indexing remains a device check. [PR #15](https://github.com/scottleibrand/TinFoilKit-iOS/pull/15)

## Cloud branches awaiting integration

- `codex/regional-download-fixture` adds a resumable Python downloader and interrupted-transfer fixture. Compare `codex/ios-regional-download` and `codex/persistent-regional-download` before landing the iOS flow. `codex/regional-data-candidate` documents a candidate production region and its provenance.
- `codex/ask-offline-directions`, `codex/ask-saved-pin-directions`, and `codex/ask-address-directions` touch related Ask and Map paths. Compare their intent handling before combining the changes. `codex/offline-ask-retrieval-fixture` adds coverage for retrieval across installed PDF archives.
- `codex/nearby-public-admission` adds catalog and storage admission checks. `codex/nearby-public-resume` and `codex/nearby-public-transfer-recovery` overlap on worksheet download resume. Review their shared transfer paths and verify the combined behavior.
- `codex/map-range-validation` adds validation for remote PMTiles range responses. `codex/desktop-starter-packs` and `codex/catalog-audit` carry the same climate pack byte count correction. Verify any publisher metadata before integrating it.
- `codex/optional-health-library` adds an individual WikiMed download. `codex/print-essentials-edition-audit` tracks exact printable editions and page ranges. `codex/archive-directory-paths` addresses resource paths ending in a slash.
- `codex/household-share-link-controls` adds link rotation and a locally rendered QR code. `codex/household-share-public-worksheet` adds the verified worksheet to the household browser share. Review the access controls and expiration on a second device.

## Work that can move in the cloud

| Work | Cloud acceptance check |
| --- | --- |
| Regional map packages | Draft a catalog entry consumable by a resumable regional downloader and verify the recovery fixture above. Record publisher provenance and redistribution terms for a candidate production region. Keep generated assets and source extracts out of Git. Use the pinned Valhalla container to run the full producer test. |
| Catalog and publisher downloads | Start with the climate byte count proposed on `codex/catalog-audit`. Continue auditing pinned URLs, exact editions, byte counts, hashes, language and terms. Confirm resume support using small actual range requests with capped responses. Expand versions and mirror metadata only with publisher evidence. |
| Nearby public content | Work on deterministic, portable components for manifest validation, provenance, inventory matching, disk reservations and resume checkpoints. Use synthetic bytes to test interruptions, stale checkpoints, duplicates and disk limits. Reuse the existing Nearby implementation. Automatic public exchange requires an enabled setting, verified redistribution rights and sufficient storage. |
| Ask and parity audit | Reconcile the desktop workflow inventory on `codex/desktop-parity-audit` with current main. Reuse the directions branches above. Expand deterministic fixtures as needed and leave the existing library search path for general questions. Develop synthetic retrieval and reader byte-range fixtures. |

Start with the routing format tests, which require Python 3.10 or later.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 Tests/RoutingPackFixture/test_routing_pack.py
PYTHONDONTWRITEBYTECODE=1 python Tests/RegionalBundleFixture/run.py
git diff --check
```

The regional fixture needs `osmium==4.2.0`, Docker and access to the pinned image. The Swift place, Nearby and download runners target a Mac. Portable Swift code can be compiled with Linux Swift when its imports and test harness allow it. App integration requires the Xcode checks below. If tools are unavailable, record the exact command and blocker in the feature branch or PR description.

Public web snapshots must have verified rights, provenance and no personal context before automatic exchange. Files imports and saved questions and answers require explicit consent for the exact items and recipient. Preserve those boundaries in fixtures. Keep credentials, private files, excerpts from real Ask history, device identifiers and generated outputs out of the branch.

## Verify back on the Mac

- Prepare the linked reader, maps and routing assets and run XcodeGen using the [README](README.md#build-locally). Run the app and library tests on explicit simulators with isolated DerivedData and synthetic fixtures. Build both profiles when packaging changes.
- For downloads, run `python3 Tests/PackDownloadFixture/test_resume.py` on macOS. Test the app with an interrupted background pack transfer on the phone, reconnect on the same allowed network, and confirm the publisher is asked for the remaining bytes and the final checksum passes. Cover pause, relaunch, longer outages and cellular consent. Map tiles already saved should survive an interruption.
- For regional packages, add an in-app catalog download flow that hands completed files to the verified importer. Exercise verification, cancellation and recovery with fixtures, then test addresses, services, and walking and driving routes after an iPhone cold launch in airplane mode. For Ask, verify external map handoff in airplane mode and the real on-device model on an eligible phone.
- For Nearby, use two iPhones with Wi-Fi enabled and no access point, then repeat on a LAN without internet. Check permission, storage limits, progress after interruption, notification behavior, and consent on real devices. The cloud cannot verify iOS suspension, direct peer discovery or Wi-Fi Aware.
- Run each PR’s signed standard iPhone build alongside simulator testing in separate DerivedData directories. Install on the paired iPhone when reachable, and report any remaining device checks before merging. The requested TestFlight upload is a separate one-time lightweight release.
