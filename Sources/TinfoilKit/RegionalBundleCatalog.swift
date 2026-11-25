import Foundation

enum RegionalBundleCatalog {
    struct Entry: Identifiable, Sendable {
        let id: String
        let region: String
        let edition: String
        let byteCount: Int64
        let source: RegionalBundleDownloadSource

        func matches(_ manifest: RegionalBundleManifest) -> Bool {
            guard manifest.schemaVersion == 2, manifest.assets.basemap != nil,
                  manifest.region == region, manifest.dataVersion == edition else { return false }
            var total: Int64 = 0
            for asset in manifest.assets.downloadFiles {
                let (sum, overflow) = total.addingReportingOverflow(asset.byteCount)
                guard asset.byteCount > 0, !overflow else { return false }
                total = sum
            }
            return total == byteCount
        }
    }

    static var entries: [Entry] {
        #if DEBUG
        if let fixture = fixtureEntry(arguments: ProcessInfo.processInfo.arguments) { return [fixture] }
        #endif
        guard let source = try? RegionalBundleDownloadSource(
            url: "https://github.com/scottleibrand/TinFoilKit-iOS/releases/download/region-seattle-2026-11-21/manifest.json",
            sha256: "3480364f81f25611121baf9a22b9f0ad1a5a9952169e10594caa9ebfac80a352"
        ) else { return [] }
        return [
            Entry(id: "seattle-2026-11-21", region: "Seattle area", edition: "2026-11-21T00:00:00Z",
                  byteCount: 318_339_726, source: source)
        ]
    }

    #if DEBUG
    static func fixtureEntry(arguments: [String]) -> Entry? {
        func value(_ flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else { return nil }
            return arguments[index + 1]
        }

        guard let address = value("-regionalCatalogFixtureURL"),
              let digest = value("-regionalCatalogFixtureSHA256"),
              let size = value("-regionalCatalogFixtureBytes"),
              let byteCount = Int64(size), byteCount > 0,
              let source = try? RegionalBundleDownloadSource(url: address, sha256: digest),
              let host = URLComponents(string: address)?.percentEncodedHost,
              ["127.0.0.1", "[::1]", "::1"].contains(host),
              source.url.lastPathComponent == "manifest.json", source.url.query == nil else { return nil }
        return Entry(id: "synthetic-regional-fixture", region: "Synthetic region", edition: "fixture-v1",
                     byteCount: byteCount, source: source)
    }
    #endif
}
