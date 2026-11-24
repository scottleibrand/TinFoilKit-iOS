# Cloud handoff

The goal is desktop feature parity for Tinfoil Kit on iOS. [PLAN.md](PLAN.md) tracks parity and [DISASTER-SHARING.md](DISASTER-SHARING.md) tracks nearby exchange. This handoff is for a Linux cloud session while the Mac and iPhone are offline.

## Start here

Fetch `origin`, check `origin/develop` and `origin/main`, and review any commits newer than this handoff. Both branches were synced at `391b4b9` after [pack download recovery](https://github.com/scottleibrand/TinFoilKit-iOS/pull/8). The loopback fixture recovered from two consecutive connection drops, 53 simulator unit tests passed, and the signed build was installed on the paired iPhone. Physical background transfer interruption remains a device check.

Use a fresh `codex/` feature branch from the current `origin/develop` for work awaiting Apple tests. Keep each feature in its own commits so it can move to `develop` after verification. Push the feature branch for the Mac session to retrieve. Open and merge one tested feature at a time through a `develop` → `main` PR.

The upstream desktop checkout and generated build inputs are ignored. For parity review, clone [the desktop repository](https://github.com/tudor-city-ventures/tinfoil-kit) into `upstream/tinfoil-kit` and check out `64179271bcebffc5d76f1e3d13d2592e0089b6b1`. Reuse the documented interfaces and behavior without copying copyleft code. Keep original code MIT and track dependencies, models and dataset rights in [THIRD-PARTY.md](THIRD-PARTY.md).

## Work that can move in the cloud

| Work | Cloud acceptance check |
| --- | --- |
| Regional map packages | Extend the existing offline place and routing builders into a catalog-ready regional bundle. Build one small synthetic bundle with pinned inputs, validate its manifests and hashes, and document attribution. Keep downloaded and generated data out of Git. Production routing builds need access to the pinned Valhalla container and a Docker runtime. |
| Catalog and publisher downloads | Audit pinned URLs, exact editions, byte counts, hashes, language and terms. Confirm resume support using small actual range requests that cap the response size. Expand versions and mirror metadata only with publisher evidence. Use a small local HTTP fixture for transport failures and checksum changes. |
| Nearby public content | Work on deterministic, portable components for manifest validation, provenance, inventory matching, disk reservations and resume checkpoints. Use synthetic bytes to test interruptions, stale checkpoints, duplicates and disk limits. Reuse the existing Nearby implementation. Automatic public exchange requires an enabled setting, verified redistribution rights and sufficient storage. |
| Ask and parity audit | Implement and test a pure intent parser for explicit nearby-service questions. Keep the existing search path for other questions. Plan to use installed place data and an explicit saved origin in the app. Inventory gaps against the pinned desktop checkout and add synthetic retrieval and pack metadata fixtures. |

Start with the routing format tests, which require Python 3.10 or later.

```sh
PYTHONDONTWRITEBYTECODE=1 python3 Tests/RoutingPackFixture/test_routing_pack.py
git diff --check
```

The place index builder also uses `osmium==4.2.0`. The existing Swift place, Nearby and download runners target a Mac. Portable Swift code can be compiled with Linux Swift when its imports and test harness allow it. App integration requires the Xcode checks below. If tools are unavailable, record the exact command and blocker in the feature branch or PR description.

Public web snapshots must have verified rights, provenance and no personal context before automatic exchange. Files imports and saved questions and answers require explicit consent for the exact items and recipient. Preserve those boundaries in fixtures. Keep credentials, private files, excerpts from real Ask history, device identifiers and generated outputs out of the branch.

## Verify back on the Mac

- Prepare the linked reader, maps and routing assets and run XcodeGen using the [README](README.md#build-locally). Run the app and library tests on explicit simulators with isolated DerivedData and synthetic fixtures. Build both profiles when packaging changes.
- For downloads, run `python3 Tests/PackDownloadFixture/test_resume.py` on macOS. Test the app with an interrupted background pack transfer on the phone, reconnect on the same allowed network, and confirm the publisher is asked for the remaining bytes and the final checksum passes. Cover pause, relaunch, longer outages and cellular consent. Map tiles already saved should survive an interruption.
- For regional packages, import on an iPhone and test addresses, services, and walking and driving routes after a cold launch in airplane mode. For Ask, test the app navigation and the real on-device model on an eligible phone.
- For Nearby, use two iPhones with Wi-Fi enabled and no access point, then repeat on a LAN without internet. Check permission, storage limits, progress after interruption, notification behavior, and consent on real devices. The cloud cannot verify iOS suspension, direct peer discovery or Wi-Fi Aware.
- Sign and install each completed feature on the paired iPhone when reachable. Report any remaining device checks before merging the tested PR.
