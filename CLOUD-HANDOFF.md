# Cloud handoff

The goal is desktop feature parity for Tinfoil Kit on iOS. [PLAN.md](PLAN.md) tracks parity and [DISASTER-SHARING.md](DISASTER-SHARING.md) tracks nearby exchange. This handoff is for a Linux cloud session while the Mac and iPhone are offline.

## Start here

Fetch `origin` and check both `origin/develop` and `origin/main`. Both branches were synced at `fd840e0` after PR #10. Recheck the branch tips and the work below before starting an overlapping change.

Use a fresh `codex/` feature branch from the current `origin/develop` for work awaiting Apple tests. Keep each feature in its own commits so it can move to `develop` after verification. Push the feature branch for the Mac session to retrieve. Open and merge one tested feature at a time through a `develop` → `main` PR.

The upstream desktop checkout and generated build inputs are ignored. For parity review, clone [the desktop repository](https://github.com/tudor-city-ventures/tinfoil-kit) into `upstream/tinfoil-kit` and check out `64179271bcebffc5d76f1e3d13d2592e0089b6b1`. Reuse the documented interfaces and behavior without copying copyleft code. Keep original code MIT and track dependencies, models and dataset rights in [THIRD-PARTY.md](THIRD-PARTY.md).

## Integrated work

- Pack recovery keeps the saved transfer's network policy. A loopback test verified recovery after two connection drops. A live publisher download interrupted while the iPhone app is backgrounded remains a device check. [PR #8](https://github.com/scottleibrand/TinFoilKit-iOS/pull/8)
- Ask finds the nearest requested service using saved Home and installed place data. The result opens in Tinfoil Kit Map or passes the destination coordinates to Google Maps. Synthetic lookup and both controls passed in the simulator. Keep the separate `codex/ask-nearby-intent` branch as a reference for wording coverage. [PR #9](https://github.com/scottleibrand/TinFoilKit-iOS/pull/9)
- The regional bundle builder produces a place index and routing pack from one pinned extract. The Valhalla ARM64 producer fixture passed, including rejection of corrupt artifacts and incompatible routing metadata. Five iOS storage and import tests passed and the signed app was installed. The app currently imports the two artifacts separately. [PR #10](https://github.com/scottleibrand/TinFoilKit-iOS/pull/10)

## Work that can move in the cloud

| Work | Cloud acceptance check |
| --- | --- |
| Regional map packages | Extend the landed producer with a separately sourced PMTiles basemap for the same region. Record its own edition, source and license, and check coverage, exact size and SHA-256 against a synthetic fixture. Draft a catalog entry consumable by the future iOS installer. Keep generated assets and source extracts out of Git. Use the pinned Valhalla container to run the full producer test. |
| Catalog and publisher downloads | Start with the climate byte count proposed on `codex/catalog-audit`. Continue auditing pinned URLs, exact editions, byte counts, hashes, language and terms. Confirm resume support using small actual range requests with capped responses. Expand versions and mirror metadata only with publisher evidence. |
| Nearby public content | Work on deterministic, portable components for manifest validation, provenance, inventory matching, disk reservations and resume checkpoints. Use synthetic bytes to test interruptions, stale checkpoints, duplicates and disk limits. Reuse the existing Nearby implementation. Automatic public exchange requires an enabled setting, verified redistribution rights and sufficient storage. |
| Ask and parity audit | Reconcile the desktop workflow inventory on `codex/desktop-parity-audit` with current main. For deterministic routing questions, develop intent fixtures that require an explicit destination or saved pin and travel mode. Leave the existing library search path for general questions. Develop synthetic retrieval and reader byte-range fixtures. |

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
- For regional packages, connect the manifest to one Map install flow. Exercise verification, cancellation and recovery with fixtures, then test addresses, services, and walking and driving routes after an iPhone cold launch in airplane mode. For Ask, verify external map handoff in airplane mode and the real on-device model on an eligible phone.
- For Nearby, use two iPhones with Wi-Fi enabled and no access point, then repeat on a LAN without internet. Check permission, storage limits, progress after interruption, notification behavior, and consent on real devices. The cloud cannot verify iOS suspension, direct peer discovery or Wi-Fi Aware.
- Sign and install each completed feature on the paired iPhone when reachable. Report any remaining device checks before merging the tested PR.
