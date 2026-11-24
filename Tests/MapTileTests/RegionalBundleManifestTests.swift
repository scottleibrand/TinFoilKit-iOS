import XCTest
@testable import TinfoilKit

final class RegionalBundleManifestTests: XCTestCase {
    func testProducerManifestMatchesPlaceAndRoutingMetadata() throws {
        let manifest = try readFixture()
        XCTAssertEqual(manifest.region, "Synthetic region")
        XCTAssertEqual(manifest.assets.places.filename, "places.sqlite")
        XCTAssertEqual(manifest.assets.routing.byteCount, 6)
        XCTAssertNil(manifest.assets.basemap)

        let bounds = manifest.bounds
        let places = RegionalPlaceIndex.Metadata(
            region: manifest.region, source: manifest.source, attribution: manifest.attribution,
            license: manifest.license, licenseURL: manifest.licenseURL, dataVersion: manifest.dataVersion,
            placeCount: 1, bounds: .init(west: bounds.west, south: bounds.south, east: bounds.east, north: bounds.north)
        )
        XCTAssertNoThrow(try manifest.validate(places: places))
        let noCoverage = RegionalPlaceIndex.Metadata(
            region: places.region, source: places.source, attribution: places.attribution,
            license: places.license, licenseURL: places.licenseURL, dataVersion: places.dataVersion,
            placeCount: places.placeCount, bounds: nil
        )
        XCTAssertThrowsError(try manifest.validate(places: noCoverage)) {
            XCTAssertEqual($0 as? RegionalBundleManifest.Error, .metadataMismatch("places.sqlite"))
        }

        XCTAssertNoThrow(try manifest.validate(routing: route(from: manifest, sourceSHA256: manifest.sourceSHA256)))
        XCTAssertThrowsError(try manifest.validate(routing: route(from: manifest, sourceSHA256: digest("d")))) {
            XCTAssertEqual($0 as? RegionalBundleManifest.Error, .metadataMismatch("routing.tfkroute"))
        }
    }

    func testVersionTwoUsesIndependentBasemapProvenanceAndCoverage() throws {
        let versionTwo = fixture.replacingOccurrences(of: #""schemaVersion": 1"#, with: #""schemaVersion": 2"#)
            .replacingOccurrences(of: #""routing": {"#, with: """
            "basemap": {
              "filename": "basemap.pmtiles",
              "url": "https://example.invalid/bundles/v1/basemap.pmtiles",
              "byteCount": 159,
              "sha256": "\(digest("d"))",
              "dataVersion": "map-edition",
              "source": "https://maps.example.invalid/map.pmtiles",
              "license": "MIT",
              "licenseURL": "https://opensource.org/license/mit",
              "attribution": "Synthetic basemap",
              "bounds": {"west": -122.006, "south": 47.495, "east": -121.998, "north": 47.505}
            },
            "routing": {
            """)
        let manifest = try readFixture(json: versionTwo)
        let basemap = try XCTUnwrap(manifest.assets.basemap)
        XCTAssertEqual(basemap.dataVersion, "map-edition")
        XCTAssertEqual(basemap.license, "MIT")
        XCTAssertEqual(basemap.source.host, "maps.example.invalid")
        XCTAssertNoThrow(try manifest.validate(basemapBounds: basemap.bounds))
        XCTAssertThrowsError(try manifest.validate(basemapBounds: manifest.bounds)) {
            XCTAssertEqual($0 as? RegionalBundleManifest.Error, .metadataMismatch("basemap.pmtiles"))
        }
        for (needle, replacement, expected) in [
            (#""schemaVersion": 2"#, #""schemaVersion": 1"#, RegionalBundleManifest.Error.invalidManifest),
            ("maps.example.invalid", "user@maps.example.invalid", .metadataMismatch("basemap.pmtiles")),
            (#""west": -122.006"#, #""west": -122.004"#, .metadataMismatch("basemap.pmtiles"))
        ] {
            XCTAssertThrowsError(try readFixture(json: versionTwo.replacingOccurrences(of: needle, with: replacement))) {
                XCTAssertEqual($0 as? RegionalBundleManifest.Error, expected)
            }
        }
    }

    func testReaderRejectsUnsafeFilesAndURLs() throws {
        let invalid: [(String, String, RegionalBundleManifest.Error)] = [
            (#""schemaVersion": 1"#, #""schemaVersion": 2"#, .invalidManifest),
            (#""west": -122.005"#, #""west": -190"#, .invalidManifest),
            ("https://example.invalid/region.osm.pbf", "https://user@example.invalid/region.osm.pbf", .invalidManifest),
            (#""filename": "places.sqlite""#, #""filename": "../places.sqlite""#, .invalidArtifact("places.sqlite")),
            ("v1/places.sqlite", "v1/other.sqlite", .invalidArtifact("places.sqlite")),
            (#""byteCount": 4"#, #""byteCount": 0"#, .invalidArtifact("places.sqlite")),
            (digest("b"), digest("G"), .invalidArtifact("places.sqlite"))
        ]
        for (needle, replacement, expected) in invalid {
            XCTAssertThrowsError(try readFixture(replacing: needle, with: replacement)) {
                XCTAssertEqual($0 as? RegionalBundleManifest.Error, expected, needle)
            }
        }
    }

    func testManifestAndArtifactMustBeRegularFilesWithExpectedSizes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.json")
        try Data(fixture.utf8).write(to: target)
        let link = directory.appendingPathComponent("manifest.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(try RegionalBundleManifest.read(from: link)) {
            XCTAssertEqual($0 as? RegionalBundleManifest.Error, .invalidManifest)
        }

        let manifest = try RegionalBundleManifest.read(from: target)
        try Data(repeating: 32, count: 65_537).write(to: target)
        XCTAssertThrowsError(try RegionalBundleManifest.read(from: target))

        let file = directory.appendingPathComponent("places.sqlite")
        try Data([1, 2, 3, 4]).write(to: file)
        XCTAssertNoThrow(try manifest.assets.places.validateFile(at: file))
        XCTAssertThrowsError(try manifest.assets.routing.validateFile(at: file))
        let alias = directory.appendingPathComponent("symlink.sqlite")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: file)
        XCTAssertThrowsError(try manifest.assets.places.validateFile(at: alias))
    }

    private func route(from manifest: RegionalBundleManifest, sourceSHA256: String) -> RoutingPack {
        RoutingPack(
            schemaVersion: 1, region: manifest.region, dataVersion: manifest.dataVersion,
            engineVersion: RoutingPack.engine, engineCommit: RoutingPack.engineRevision,
            timeZoneDataVersion: RoutingPack.timezoneVersion, bounds: manifest.bounds, source: manifest.source,
            sourceSHA256: sourceSHA256, attribution: manifest.attribution, license: manifest.license,
            licenseURL: manifest.licenseURL, graphByteCount: 1536, graphSHA256: digest("c")
        )
    }

    private func readFixture(replacing original: String? = nil, with replacement: String = "") throws
        -> RegionalBundleManifest {
        let json = original.map { fixture.replacingOccurrences(of: $0, with: replacement) } ?? fixture
        return try readFixture(json: json)
    }

    private func readFixture(json: String) throws -> RegionalBundleManifest {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("manifest.json")
        try Data(json.utf8).write(to: url)
        return try RegionalBundleManifest.read(from: url)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func digest(_ character: String) -> String { String(repeating: character, count: 64) }

    private var fixture: String {
        """
        {
          "schemaVersion": 1,
          "region": "Synthetic region",
          "dataVersion": "fixture-v1",
          "source": "https://example.invalid/region.osm.pbf",
          "sourceSHA256": "\(digest("a"))",
          "bounds": {"west": -122.005, "south": 47.496, "east": -121.999, "north": 47.504},
          "artifactBaseURL": "https://example.invalid/bundles/v1/",
          "attribution": "© OpenStreetMap contributors",
          "license": "ODbL-1.0",
          "licenseURL": "https://www.openstreetmap.org/copyright",
          "assets": {
            "places": {
              "filename": "places.sqlite",
              "url": "https://example.invalid/bundles/v1/places.sqlite",
              "byteCount": 4,
              "sha256": "\(digest("b"))"
            },
            "routing": {
              "filename": "routing.tfkroute",
              "url": "https://example.invalid/bundles/v1/routing.tfkroute",
              "byteCount": 6,
              "sha256": "\(digest("c"))"
            }
          }
        }
        """
    }
}
