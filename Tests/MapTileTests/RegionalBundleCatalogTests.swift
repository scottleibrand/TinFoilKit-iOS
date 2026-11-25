import Foundation
import XCTest
@testable import TinfoilKit

final class RegionalBundleCatalogTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private let base = URL(string: "https://example.invalid/bundle/")!

    func testEntryRequiresExactIdentityAndThreeAssetByteCount() throws {
        let source = try RegionalBundleDownloadSource(url: base.appendingPathComponent("manifest.json").absoluteString,
                                                     sha256: digest)
        let entry = RegionalBundleCatalog.Entry(id: "fixture", region: "Synthetic region", edition: "fixture-v1",
                                                byteCount: 700, source: source)

        XCTAssertTrue(entry.matches(manifest()))
        XCTAssertFalse(entry.matches(manifest(region: "Other region")))
        XCTAssertFalse(entry.matches(manifest(edition: "fixture-v2")))
        XCTAssertFalse(entry.matches(manifest(version: 1)))
        XCTAssertFalse(entry.matches(manifest(includeBasemap: false)))
        XCTAssertFalse(entry.matches(manifest(placeBytes: 101)))
        XCTAssertFalse(entry.matches(manifest(placeBytes: .max)))
    }

    #if DEBUG
    func testOnlyLiteralHTTPSLoopbackCanSupplyDebugFixture() throws {
        func fixture(_ url: String, sha256: String? = nil, bytes: String = "700") -> RegionalBundleCatalog.Entry? {
            RegionalBundleCatalog.fixtureEntry(arguments: [
                "-regionalCatalogFixtureURL", url, "-regionalCatalogFixtureSHA256", sha256 ?? digest,
                "-regionalCatalogFixtureBytes", bytes
            ])
        }

        let url = "https://127.0.0.1:8443/bundle/manifest.json"
        let entry = try XCTUnwrap(fixture(url))
        XCTAssertEqual(entry.id, "synthetic-regional-fixture")
        XCTAssertEqual(entry.source.url.absoluteString, url)
        XCTAssertEqual(entry.source.sha256, digest)
        XCTAssertTrue(entry.matches(manifest()))
        XCTAssertNotNil(fixture("https://[::1]:8443/bundle/manifest.json"))
        XCTAssertNil(fixture("http://127.0.0.1:8443/bundle/manifest.json"))
        XCTAssertNil(fixture("https://localhost:8443/bundle/manifest.json"))
        XCTAssertNil(fixture("https://127.0.0.1.example.invalid/bundle/manifest.json"))
        XCTAssertNil(fixture("https://user@127.0.0.1:8443/bundle/manifest.json"))
        XCTAssertNil(fixture("https://127.0.0.1:8443/bundle/other.json"))
        XCTAssertNil(fixture(url, sha256: "missing"))
        XCTAssertNil(fixture(url, bytes: "0"))
        XCTAssertNil(RegionalBundleCatalog.fixtureEntry(arguments: []))
    }
    #endif

    private func manifest(region: String = "Synthetic region", edition: String = "fixture-v1", version: Int = 2,
                          includeBasemap: Bool = true, placeBytes: Int64 = 100) -> RegionalBundleManifest {
        let bounds = RoutingPack.Bounds(west: -122.005, south: 47.496, east: -121.999, north: 47.504)
        let source = URL(string: "https://example.invalid/region.osm.pbf")!
        let license = URL(string: "https://www.openstreetmap.org/copyright")!
        let basemap = RegionalBundleManifest.Basemap(
            filename: "basemap.pmtiles", url: base.appendingPathComponent("basemap.pmtiles"), byteCount: 400,
            sha256: digest, dataVersion: "map-fixture-v2", source: source, license: "MIT", licenseURL: license,
            attribution: "Tinfoil Kit synthetic basemap fixture", bounds: bounds
        )
        let places = RegionalBundleManifest.Asset(filename: "places.sqlite", url: base.appendingPathComponent("places.sqlite"),
                                                 byteCount: placeBytes, sha256: digest)
        let routing = RegionalBundleManifest.Asset(filename: "routing.tfkroute", url: base.appendingPathComponent("routing.tfkroute"),
                                                  byteCount: 200, sha256: digest)
        return RegionalBundleManifest(
            schemaVersion: version, region: region, dataVersion: edition, source: source, sourceSHA256: digest,
            bounds: bounds, artifactBaseURL: base, attribution: "© OpenStreetMap contributors", license: "ODbL-1.0",
            licenseURL: license, assets: .init(places: places, routing: routing, basemap: includeBasemap ? basemap : nil)
        )
    }
}
