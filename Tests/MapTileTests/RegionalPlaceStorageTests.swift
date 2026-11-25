import CoreLocation
import CryptoKit
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
        try makeIndex(at: west, region: "West", longitude: 10, address: "325 9th Avenue, West")
        try makeIndex(at: east, region: "East", longitude: 10.05, address: "325 9th Avenue, East")
        try makeIndex(at: duplicate, region: "Overlap", longitude: 10, name: "West Hospital",
                      address: "325 9th Avenue, West")
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

        let exact = try XCTUnwrap(HomeRouteQuestion.parse("Walk from Home to 325 9th Avenue, West"))
        let exactMatches = try await RegionalPlaceSearch.destinationsInstalled(matching: exact, from: home, storage: storage)
        XCTAssertEqual(exactMatches?.map(\.place.name), ["West Hospital"])
        let ambiguous = try XCTUnwrap(HomeRouteQuestion.parse("Drive from Home to 325 9th Avenue"))
        let ambiguousMatches = try await RegionalPlaceSearch.destinationsInstalled(matching: ambiguous, from: home,
                                                                                   storage: storage)
        XCTAssertEqual(Set(ambiguousMatches?.map(\.place.name) ?? []), ["East Hospital", "West Hospital"])
        let noIndexes = try await RegionalPlaceSearch.destinationsInstalled(matching: exact, from: home,
                                                                            storage: emptyStorage)
        XCTAssertNil(noIndexes)
    }

    func testNamedDestinationRequiresExactNameAndPreservesDistinctLocations() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = RegionalPlaceStorage(directory: root.appendingPathComponent("Places"))
        let home = HouseholdPlace(name: "Home", latitude: 45, longitude: 10)
        let fixtures = [
            ("West", 10.0, "Harbor Medical Center"),
            ("East", 10.05, "Harbor Medical Center"),
            ("Overlap", 10.0, "Harbor Medical Center"),
            ("Annex", 10.1, "Harbor Medical Center Annex")
        ]
        for (region, longitude, name) in fixtures {
            let source = root.appendingPathComponent("\(region).sqlite")
            try makeIndex(at: source, region: region, longitude: longitude, name: name)
            _ = try await storage.install(source)
        }

        let exact = try XCTUnwrap(HomeRouteQuestion.parse("Walk from Home to Hárbor Medical Center?"))
        let matches = try await RegionalPlaceSearch.destinationsInstalled(matching: exact, from: home, storage: storage)
        XCTAssertEqual(matches?.count, 2)
        XCTAssertEqual(Set(matches?.map(\.place.coordinate.longitude) ?? []), [10.0, 10.05])

        let partial = try XCTUnwrap(HomeRouteQuestion.parse("Walk from Home to Harbor Medical"))
        let partialMatches = try await RegionalPlaceSearch.destinationsInstalled(matching: partial, from: home,
                                                                                 storage: storage)
        XCTAssertEqual(partialMatches?.count, 0)
    }

    func testRegionalBundlePublishesAndRemovesPlaceDataAndRoutesTogether() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try makeRegionalBundle(at: source)
        let directory = root.appendingPathComponent("Bundles", isDirectory: true)
        let placeStore = RegionalPlaceStorage(directory: root.appendingPathComponent("Places"), bundleDirectory: directory)
        let routeStore = RegionalRouteStore(directory: root.appendingPathComponent("Routes"), bundleDirectory: directory)
        let storage = RegionalBundleStorage(directory: directory)

        let installed = try await storage.install(source)
        let reopened = RegionalBundleStorage(directory: directory)
        let duplicate = try await reopened.install(source)
        XCTAssertEqual(duplicate.id, installed.id)

        let place = try await placeStore.current()
        XCTAssertEqual(place?.bundleID, installed.id)
        XCTAssertEqual(try place?.index.search("hospital").first?.name, "Fixture Hospital")
        let graph = try await routeStore.current()
        XCTAssertEqual(graph?.bundleID, installed.id)
        let east = MapRoute.Point(latitude: 47.50002, longitude: -122.0004)
        let west = MapRoute.Point(latitude: 47.50003, longitude: -122.0035)
        let walk = try await routeStore.route(from: east, to: west, mode: .walking)
        let drive = try await routeStore.route(from: east, to: west, mode: .driving)
        XCTAssertFalse(walk.steps.isEmpty)
        XCTAssertGreaterThan(drive.meters, 3 * walk.meters)
        let selected = try XCTUnwrap(graph)
        let selectedWalk = try await routeStore.route(selected, from: east, to: west, mode: .walking)
        XCTAssertEqual(selectedWalk.meters, walk.meters)

        try await placeStore.remove(try XCTUnwrap(place?.id))
        try await routeStore.remove(installed.id)
        let stillInstalled = try await reopened.installedBundles()
        XCTAssertEqual(stillInstalled.map(\.id), [installed.id])
        try await reopened.remove(installed.id)
        let indexes = try await placeStore.installedIndexes()
        let graphs = try await routeStore.installedPacks()
        XCTAssertTrue(indexes.isEmpty)
        XCTAssertTrue(graphs.isEmpty)
    }

    func testInvalidBundleLeavesNoAssetsOrStagingDirectory() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        try makeRegionalBundle(at: source)
        let routing = source.appendingPathComponent("routing.tfkroute")
        var bytes = try Data(contentsOf: routing)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: routing)
        let directory = root.appendingPathComponent("Bundles", isDirectory: true)
        let storage = RegionalBundleStorage(directory: directory)
        do {
            _ = try await storage.install(source)
            XCTFail("A modified graph must fail bundle validation")
        } catch RegionalBundleManifest.Error.invalidArtifact("routing.tfkroute") {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testBasemapPublishesAndRemovesWithItsEdition() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("Source", isDirectory: true)
        let tile = basemapFixture()
        try makeRegionalBundle(at: source, basemap: tile)
        let directory = root.appendingPathComponent("Bundles", isDirectory: true)
        let maps = root.appendingPathComponent("Maps")
        let store = MapStorage(directory: maps, bundledMap: nil, bundleDirectory: directory)
        let places = RegionalPlaceStorage(directory: root.appendingPathComponent("Places"), bundleDirectory: directory)
        let routes = RegionalRouteStore(directory: root.appendingPathComponent("Routes"), bundleDirectory: directory)
        let bundles = RegionalBundleStorage(directory: directory)

        let bundle = try await bundles.install(source)
        let available = try await store.installedMaps()
        let map = try XCTUnwrap(available.first)
        XCTAssertEqual(available.count, 1)
        XCTAssertEqual(map.regionalBundleID, bundle.id)
        XCTAssertEqual(map.bounds, bundle.manifest.assets.basemap?.bounds)
        XCTAssertEqual(map.licenseURL, bundle.manifest.assets.basemap?.licenseURL)
        XCTAssertFalse(map.canRemove)
        XCTAssertEqual(try Data(contentsOf: map.archive), tile)
        let reader = PMTileArchive(url: map.archive)
        let vectorTile = try await reader.vectorTile(MapTile(zoom: 0, x: 0, y: 0))
        XCTAssertNotNil(vectorTile)
        let place = try await places.current()
        let route = try await routes.current()
        XCTAssertEqual(place?.bundleID, bundle.id)
        XCTAssertEqual(route?.bundleID, bundle.id)

        let standaloneFile = root.appendingPathComponent("Standalone.pmtiles")
        try tile.write(to: standaloneFile)
        let standalone = try await store.importMap(from: standaloneFile)
        XCTAssertTrue(standalone.canRemove)
        _ = try await store.selectMap(map.id)
        let reopened = MapStorage(directory: maps, bundledMap: nil, bundleDirectory: directory)
        let selected = try await reopened.current()
        XCTAssertEqual(selected, map)
        try await reopened.removeMap(map.id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: map.archive.path))
        try FileManager.default.removeItem(at: map.archive)
        let damaged = try await bundles.installedBundles()
        XCTAssertEqual(damaged.map(\.id), [bundle.id])
        XCTAssertFalse(try XCTUnwrap(damaged.first).isUsable)
        let visibleMaps = try await reopened.installedMaps()
        XCTAssertEqual(visibleMaps, [standalone])
        try await bundles.remove(bundle.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: map.archive.path))
        let fallback = try await reopened.current()
        let remainingPlaces = try await places.installedIndexes()
        let remainingRoutes = try await routes.installedPacks()
        XCTAssertEqual(fallback, standalone)
        XCTAssertTrue(remainingPlaces.isEmpty)
        XCTAssertTrue(remainingRoutes.isEmpty)
    }

    func testBadBasemapNeverPublishesAnyBundleAssets() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Bundles", isDirectory: true)
        let storage = RegionalBundleStorage(directory: directory)
        let validBytes = basemapFixture()
        let corrupt = root.appendingPathComponent("Wrong digest", isDirectory: true)
        try makeRegionalBundle(at: corrupt, basemap: validBytes)
        var wrongDigest = validBytes
        wrongDigest[wrongDigest.count - 1] ^= 1
        try wrongDigest.write(to: corrupt.appendingPathComponent("basemap.pmtiles"))

        let malformed = root.appendingPathComponent("Wrong layout", isDirectory: true)
        var wrongLayout = validBytes
        wrongLayout[56] = 255
        try makeRegionalBundle(at: malformed, basemap: wrongLayout)

        let compressed = root.appendingPathComponent("Unsupported compression", isDirectory: true)
        var wrongCompression = validBytes
        wrongCompression[97] = 3
        try makeRegionalBundle(at: compressed, basemap: wrongCompression)

        let mismatched = root.appendingPathComponent("Wrong bounds", isDirectory: true)
        var wrongBounds = validBytes
        wrongBounds[102] ^= 1
        try makeRegionalBundle(at: mismatched, basemap: wrongBounds)

        for (folder, expected) in [
            (corrupt, RegionalBundleManifest.Error.invalidArtifact("basemap.pmtiles")),
            (malformed, .invalidArtifact("basemap.pmtiles")),
            (compressed, .invalidArtifact("basemap.pmtiles")),
            (mismatched, .metadataMismatch("basemap.pmtiles"))
        ] {
            do {
                _ = try await storage.install(folder)
                XCTFail("Invalid basemap should fail the bundle import")
            } catch {
                XCTAssertEqual(error as? RegionalBundleManifest.Error, expected)
            }
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }

    func testVerifiedPendingDownloadCanReplaceDamagedEdition() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let pending = root.appendingPathComponent("Pending", isDirectory: true)
        try makeRegionalBundle(at: pending, basemap: basemapFixture())
        let directory = root.appendingPathComponent("Bundles", isDirectory: true)
        let storage = RegionalBundleStorage(directory: directory)
        let original = try await storage.install(pending)
        try FileManager.default.removeItem(at: directory.appendingPathComponent(original.id.uuidString)
            .appendingPathComponent(RegionalBundleManifest.basemapFilename))
        let damaged = try await storage.installedBundles()
        XCTAssertFalse(try XCTUnwrap(damaged.first).isUsable)

        let state = RegionalDownloadState(directory: pending)
        let manifestSize = try XCTUnwrap(RegionalDownloadState.regularSize(state.manifestFile))
        let hash = try RegionalDownloadState.hash(state.manifestFile, byteCount: manifestSize)
        let source = try RegionalBundleDownloadSource(url: "https://example.invalid/manifest.json",
                                                      sha256: RegionalDownloadState.hex(hash))
        var job = RegionalDownloadState.Job(source: source, cellular: false)
        job.started = true
        try state.save(job)
        let downloader = RegionalBundleDownload(directory: pending)
        let result = try await downloader.install(in: storage) { _ in }
        XCTAssertNotEqual(result.id, original.id)
        XCTAssertTrue(result.isUsable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pending.path))
        let maps = MapStorage(directory: root.appendingPathComponent("Maps"), bundledMap: nil, bundleDirectory: directory)
        let installedMaps = try await maps.installedMaps()
        XCTAssertEqual(installedMaps.map(\.regionalBundleID), [result.id])
    }

    private func basemapFixture() -> Data {
        var bytes = Data(repeating: 0, count: 127)
        bytes.replaceSubrange(0..<7, with: "PMTiles".utf8)
        bytes[7] = 3
        bytes.replaceSubrange(96..<102, with: [UInt8(1), 1, 1, 1, 0, 0])
        // Single uncompressed z0 vector tile with one synthetic point.
        let tile: [UInt8] = [0x1a, 0x17, 0x0a, 7] + Array("fixture".utf8)
            + [0x12, 7, 0x18, 1, 0x22, 3, 9, 0, 0, 0x28, 0x80, 0x20, 0x78, 2]
        let fields: [UInt64] = [127, 5, 132, 2, 134, 0, 134, UInt64(tile.count), 1, 1, 1]
        for (index, field) in fields.enumerated() {
            let offset = 8 + 8 * index
            bytes.replaceSubrange(offset..<(offset + 8), with: withUnsafeBytes(of: field.littleEndian, Array.init))
        }
        let coordinates: [Int32] = [-1_220_060_000, 474_950_000, -1_219_980_000, 475_050_000]
        for (index, coordinate) in coordinates.enumerated() {
            let offset = 102 + 4 * index
            bytes.replaceSubrange(offset..<(offset + 4), with: withUnsafeBytes(of: coordinate.littleEndian, Array.init))
        }
        bytes.append(contentsOf: [1, 0, 1, UInt8(tile.count), 1])
        bytes.append(contentsOf: "{}".utf8)
        bytes.append(contentsOf: tile)
        return bytes
    }

    private func makeRegionalBundle(at folder: URL, basemap: Data? = nil) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let packURL = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Synthetic", withExtension: "tfkroute"))
        let packed = try Data(contentsOf: packURL)
        let length = packed.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian) }
        let pack = try JSONDecoder().decode(RoutingPack.self, from: packed[12..<(12 + length)])
        try packed.write(to: folder.appendingPathComponent("routing.tfkroute"))
        let places = folder.appendingPathComponent("places.sqlite")
        try makeIndex(at: places, region: pack.region, longitude: -122.002, name: "Fixture Hospital")
        try updatePlaceMetadata(at: places, pack: pack)

        let base = try XCTUnwrap(URL(string: "https://example.invalid/bundle/"))
        func asset(_ name: String, bytes: Data) -> RegionalBundleManifest.Asset {
            RegionalBundleManifest.Asset(filename: name, url: base.appendingPathComponent(name),
                                         byteCount: Int64(bytes.count),
                                         sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())
        }
        let mapAsset: RegionalBundleManifest.Basemap?
        if let basemap {
            let file = asset("basemap.pmtiles", bytes: basemap)
            try basemap.write(to: folder.appendingPathComponent(file.filename))
            mapAsset = .init(
                filename: file.filename, url: file.url, byteCount: file.byteCount, sha256: file.sha256,
                dataVersion: "synthetic-map-v2", source: try XCTUnwrap(URL(string: "https://example.invalid/map.pmtiles")),
                license: "MIT", licenseURL: try XCTUnwrap(URL(string: "https://opensource.org/license/mit")),
                attribution: "Tinfoil Kit synthetic basemap",
                bounds: .init(west: -122.006, south: 47.495, east: -121.998, north: 47.505)
            )
        } else {
            mapAsset = nil
        }
        let manifest = RegionalBundleManifest(
            schemaVersion: mapAsset == nil ? 1 : 2, region: pack.region, dataVersion: pack.dataVersion, source: pack.source,
            sourceSHA256: pack.sourceSHA256, bounds: pack.bounds, artifactBaseURL: base, attribution: pack.attribution,
            license: pack.license, licenseURL: pack.licenseURL,
            assets: .init(places: asset("places.sqlite", bytes: try Data(contentsOf: places)),
                          routing: asset("routing.tfkroute", bytes: packed), basemap: mapAsset)
        )
        try JSONEncoder().encode(manifest).write(to: folder.appendingPathComponent("manifest.json"))
    }

    private func updatePlaceMetadata(at url: URL, pack: RoutingPack) throws {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let bounds = pack.bounds
        let sql = """
            REPLACE INTO metadata VALUES ('source', '\(pack.source.absoluteString)'),
                ('attribution', '\(pack.attribution)'), ('dataVersion', '\(pack.dataVersion)'),
                ('bounds', '\(bounds.west),\(bounds.south),\(bounds.east),\(bounds.north)');
            UPDATE places SET latitude = 47.5;
            UPDATE place_bounds SET min_latitude = 47.5, max_latitude = 47.5;
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }

    private func makeIndex(at url: URL, region: String, longitude: Double = 10, name: String? = nil,
                           address: String = "") throws {
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
            INSERT INTO places VALUES (1, '\(title)', 'hospital', 'Hospital', '\(address)', 45, \(longitude));
            INSERT INTO place_search VALUES ('\(title)', 'Hospital', '\(address)');
            INSERT INTO place_bounds VALUES (1, 45, 45, \(longitude), \(longitude));
            """
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
    }
}
