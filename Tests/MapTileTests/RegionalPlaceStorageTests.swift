import CoreLocation
import PDFKit
import SQLite3
import XCTest
@testable import TinfoilKit

final class RegionalPlaceStorageTests: XCTestCase {
    func testImportsPreserveLegacyAndKeepLatestAcrossRelaunch() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Places", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = folder.appendingPathComponent("current.sqlite")
        let north = root.appendingPathComponent("North.sqlite")
        let south = root.appendingPathComponent("South.sqlite3")
        try makeIndex(at: legacy, region: "Legacy")
        try makeIndex(at: north, region: "North")
        try makeIndex(at: south, region: "South")

        let storage = RegionalPlaceStorage(directory: folder)
        let previous = try await storage.current()
        XCTAssertEqual(previous?.index.file, legacy)
        let first = try await storage.install(north)
        let second = try await storage.install(south)
        let reopened = RegionalPlaceStorage(directory: folder)
        let indexes = try await reopened.installedIndexes()
        XCTAssertEqual(indexes.map(\.metadata.region), ["Legacy", "North", "South"])
        XCTAssertEqual(Set(indexes.map(\.id)), ["current.sqlite", first.id, second.id])
        let latest = try await reopened.current()
        XCTAssertEqual(latest?.id, second.id)
        XCTAssertEqual(try first.index.search("North").first?.name, "North Hospital")

        try await reopened.remove(second.id)
        let remaining = try await reopened.installedIndexes()
        XCTAssertEqual(remaining.map(\.metadata.region), ["Legacy", "North"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.index.file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

    func testInvalidImportAndDamagedIndexDoNotHideInstalledRegion() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Places", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("North.sqlite")
        let invalid = root.appendingPathComponent("Broken.sqlite")
        try makeIndex(at: source, region: "North")
        try Data("not an index".utf8).write(to: invalid)

        let storage = RegionalPlaceStorage(directory: folder)
        let installed = try await storage.install(source)
        do {
            _ = try await storage.install(invalid)
            XCTFail("An invalid database was installed")
        } catch is RegionalPlaceIndex.IndexError {}
        try FileManager.default.copyItem(at: invalid, to: folder.appendingPathComponent("\(UUID().uuidString).sqlite"))
        let indexes = try await storage.installedIndexes()
        XCTAssertEqual(indexes.map(\.id), [installed.id])
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".partial") })
    }

    func testSearchAndNearbyMergeIndependentIndexes() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Places")
        let west = root.appendingPathComponent("West.sqlite")
        let east = root.appendingPathComponent("East.sqlite")
        let duplicate = root.appendingPathComponent("Duplicate.sqlite")
        try makeIndex(at: west, region: "West", longitude: 10)
        try makeIndex(at: east, region: "East", longitude: 10.05)
        try makeIndex(at: duplicate, region: "Overlap", longitude: 10, name: "West Hospital")
        let storage = RegionalPlaceStorage(directory: folder)
        for source in [west, east, duplicate] { _ = try await storage.install(source) }
        let regions = try await storage.installedIndexes()
        let search = RegionalPlaceSearch(regions: regions)
        let origin = CLLocationCoordinate2D(latitude: 45, longitude: 10.06)

        let matches = try search.search("hospital", near: origin)
        XCTAssertEqual(Set(matches.map(\.place.name)), ["West Hospital", "East Hospital"])
        XCTAssertEqual(Set(matches.map(\.id)).count, 2)
        let nearby = try search.nearest(.hospital, to: origin)
        XCTAssertEqual(nearby.map(\.match.place.name), ["East Hospital", "West Hospital"])
        let home = HouseholdPlace(name: "Home", latitude: origin.latitude, longitude: origin.longitude)
        let printed = try HouseholdPrinting.householdPDF(for: HouseholdSnapshot(home: home), regions: regions)
        let page = try XCTUnwrap(PDFDocument(data: printed)?.page(at: 0)?.string)
        XCTAssertTrue(page.contains("East Hospital"))
        XCTAssertTrue(page.contains("West Hospital"))

        let nearest = try await RegionalPlaceSearch.nearestInstalled(.hospital, from: home, storage: storage)
        guard case .match(let candidate) = nearest else { return XCTFail("Expected an installed hospital") }
        XCTAssertEqual(candidate.match.place.name, "East Hospital")
        XCTAssertLessThan(candidate.distanceMeters, 1_000)
        let differentService = try await RegionalPlaceSearch.nearestInstalled(.pharmacy, from: home, storage: storage)
        guard case .noMatch = differentService else { return XCTFail("Expected no matching pharmacy") }
        let emptyStorage = RegionalPlaceStorage(directory: root.appendingPathComponent("Empty"))
        let empty = try await RegionalPlaceSearch.nearestInstalled(.hospital, from: home, storage: emptyStorage)
        guard case .noPlaceData = empty else { return XCTFail("Expected no installed place data") }
    }

    private func makeIndex(at url: URL, region: String, longitude: Double = 10, name: String? = nil) throws {
        let title = name ?? "\(region) Hospital"
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let sql = """
            PRAGMA application_id = 0x54464B50;
            PRAGMA user_version = 1;
            CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
            INSERT INTO metadata VALUES ('region', '\(region)'), ('source', 'https://example.org/map.osm.pbf'),
                ('attribution', 'OpenStreetMap contributors'), ('license', 'ODbL-1.0'),
                ('licenseURL', 'https://www.openstreetmap.org/copyright'), ('placeCount', '1');
            CREATE TABLE places (id INTEGER PRIMARY KEY, title TEXT, category TEXT, category_words TEXT,
                address TEXT, latitude REAL, longitude REAL);
            CREATE VIRTUAL TABLE place_search USING fts5(title, category_words, address);
            CREATE VIRTUAL TABLE place_bounds USING rtree(id, min_latitude, max_latitude, min_longitude, max_longitude);
            INSERT INTO places VALUES (1, '\(title)', 'hospital', 'Hospital', '', 45, \(longitude));
            INSERT INTO place_search VALUES ('\(title)', 'Hospital', '');
            INSERT INTO place_bounds VALUES (1, 45, 45, \(longitude), \(longitude));
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
}
