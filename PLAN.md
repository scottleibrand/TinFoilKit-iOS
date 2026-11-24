# Tinfoil Kit for iOS implementation plan

Build a standalone iPhone app that opens its installed library and maps after a cold launch with no network or desktop host. Use a SwiftUI shell and keep downloadable assets separate from household data.

## 1. Offline library

- First, prove an MIT-licensed ZIM reader can build, link, and read a real archive on iOS. Evaluate zimru through a small C bridge. Pin the revision and review the dependency licenses, archive coverage, and decompression limits before adopting it. [zimru](https://github.com/jasontitus/zimru)
- Import one single-file ZIM from Files into app-managed storage. Validate it before registering it. Display its title and size, and reopen it after relaunch. Serve articles, images, styles, and internal links to an isolated WebKit reader from the archive.
- Build a local SQLite FTS5 index over article titles and text. Track indexing progress, retain stable archive and entry identifiers, and keep reading available while the index builds. Start with small archives and measure indexing time and additional storage before supporting large imports. [SQLite FTS5](https://www.sqlite.org/fts5.html)
- Accept the milestone when a user can import, search for a term found only in an article body, open the result with its images, and follow an internal link after an offline cold launch. Use small fixtures on an explicit simulator with isolated DerivedData, then verify with a representative publisher archive on an iPhone.

## 2. Content packs

- Use upstream's catalog and edition choices as inputs. Resolve a small set of publisher-hosted packs first. Record version, bytes, digest, source, and attribution for each supported asset.
- Add resumable background downloads, free-space checks for staging and indexing, and verification before install. Retain the working edition until its replacement and index are ready. Exercise interrupted downloads, low storage, and failed upgrades. [Upstream download design](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/docs/DESIGN.md#downloading)

## 3. Maps

- Render one local Protomaps region in MapLibre with packaged style assets, visible attribution, and GPS location. Test an upstream PMTiles file and cold-launch with connectivity disabled.
- Add regional place search and route previews when the prebuilt SQLite place index and routing data are ready. Verify search, routing, and coverage boundaries offline. [Upstream map design](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/docs/DESIGN.md#maps)

## 4. Answers and sharing

- Add an optional on-device model after measuring memory, latency, and thermals on the oldest supported inference device. Retrieve passages through library search, link answers to exact articles, and show the retrieved passages when evidence is insufficient. [Upstream search and answer behavior](https://github.com/tudor-city-ventures/tinfoil-kit/blob/64179271bcebffc5d76f1e3d13d2592e0089b6b1/docs/DESIGN.md#the-kit-page)
- Evaluate an optional desktop companion that talks to the existing LAN service. After pack installation is reliable, test transfer of a single verified pack between nearby phones before adding replication or shared queries.

## Release decisions

The first beta target is an offline library, pack management, and one regional basemap. Aim for a starter configuration under 10 GB, subject to measuring actual packs and index sizes. Set the minimum OS, representative map region, and device support from dependency and device tests before publishing the beta.

Original iOS work is MIT. Review exact dependency and distribution terms before shipping a GPL component. Use documented interfaces to independently deployed services where compatible, or implement the needed behavior independently. Content and model weights retain their own licenses. [Project licensing rules](AGENTS.md)
