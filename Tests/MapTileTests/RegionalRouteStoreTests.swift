import XCTest
@testable import TinfoilKit

final class RegionalRouteStoreTests: XCTestCase {
    func testMultipleGraphsSurviveRelaunchAndRouteWithMatchingCoverage() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Synthetic", withExtension: "tfkroute"))
        let subset = root.appendingPathComponent("East.tfkroute")
        try makeEasternSubset(of: source, at: subset)

        let folder = root.appendingPathComponent("Graphs", isDirectory: true)
        let store = RegionalRouteStore(directory: folder)
        let original = try await store.install(source)
        let duplicate = try await store.install(source)
        XCTAssertEqual(original.id, duplicate.id)
        let damaged = root.appendingPathComponent("Damaged.tfkroute")
        var bytes = try Data(contentsOf: source)
        bytes[bytes.count - 1] ^= 1
        try bytes.write(to: damaged)
        do {
            _ = try await store.install(damaged)
            XCTFail("An existing manifest must not bypass checksum verification")
        } catch RouteError.invalidPack {}
        let eastOnly = try await store.install(subset)

        let reopened = RegionalRouteStore(directory: folder)
        let installed = try await reopened.installedPacks()
        XCTAssertEqual(Set(installed.map(\.id)), [original.id, eastOnly.id])
        let east = MapRoute.Point(latitude: 47.50002, longitude: -122.0004)
        let west = MapRoute.Point(latitude: 47.50003, longitude: -122.0035)
        let walk = try await reopened.route(from: east, to: west, mode: .walking)
        let drive = try await reopened.route(from: east, to: west, mode: .driving)
        XCTAssertFalse(walk.steps.isEmpty)
        XCTAssertFalse(drive.steps.isEmpty)
        XCTAssertGreaterThan(drive.meters, 3 * walk.meters, "Driving respects the one-way road")

        try await reopened.remove(original.id)
        let remaining = try await reopened.installedPacks()
        XCTAssertEqual(remaining.map(\.id), [eastOnly.id])
        do {
            _ = try await reopened.route(from: east, to: west, mode: .walking)
            XCTFail("No remaining graph covers both endpoints")
        } catch RouteError.outsideRegion {}
    }

    func testLegacyPackRemainsAvailableAlongsideNewImport() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Synthetic", withExtension: "tfkroute"))
        let store = RegionalRouteStore(directory: folder)
        let original = try await store.install(source)
        let name = original.id.uuidString
        let imported = folder.appendingPathComponent("Installed").appendingPathComponent(name)
        try FileManager.default.moveItem(at: imported, to: folder.appendingPathComponent(name))
        try Data(name.utf8).write(to: folder.appendingPathComponent("current"))

        let subset = folder.appendingPathComponent("East.tfkroute")
        try makeEasternSubset(of: source, at: subset)
        let reopened = RegionalRouteStore(directory: folder)
        let eastOnly = try await reopened.install(subset)
        let packs = try await reopened.installedPacks()
        XCTAssertEqual(Set(packs.map(\.id)), [original.id, eastOnly.id])
    }

    func testGuestDirectionsUseTheInstalledEditionAndSelectedPins() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RegionalRouteStore(directory: directory)
        let source = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "Synthetic", withExtension: "tfkroute"))
        let installed = try await store.install(source)

        let home = HouseholdPlace(name: "Home", latitude: 47.50002, longitude: -122.0004)
        let pins = (0..<4).map { index in
            HouseholdPlace(name: "Pin \(index)", latitude: 47.50003, longitude: -122.0035)
        }
        let routes = await HouseholdShareDirections.prepare(for: HouseholdSnapshot(home: home, pins: pins), router: store)
        XCTAssertEqual(routes.count, 6)
        XCTAssertEqual(Set(routes.map(\.pinID)), Set(pins.prefix(3).map(\.id)))
        XCTAssertEqual(Set(routes.map(\.modeTitle)), Set(MapTravelMode.allCases.map(\.title)))
        XCTAssertTrue(routes.allSatisfy {
            $0.region == installed.pack.region && $0.edition == installed.pack.dataVersion && !$0.steps.isEmpty
        })

        let withoutHome = await HouseholdShareDirections.prepare(for: HouseholdSnapshot(pins: pins), router: store)
        XCTAssertTrue(withoutHome.isEmpty)
    }

    private func makeEasternSubset(of source: URL, at destination: URL) throws {
        let original = try Data(contentsOf: source)
        let length = original.withUnsafeBytes { Int($0.loadUnaligned(fromByteOffset: 8, as: UInt32.self).littleEndian) }
        var manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: original[12..<(12 + length)]) as? [String: Any])
        var bounds = try XCTUnwrap(manifest["bounds"] as? [String: Double])
        bounds["west"] = -122.002
        manifest["bounds"] = bounds
        manifest["region"] = "Eastern routing test fixture"
        let bytes = try JSONSerialization.data(withJSONObject: manifest)
        var size = UInt32(bytes.count).littleEndian
        var result = Data("TFKROUTE".utf8)
        withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
        result.append(bytes)
        result.append(original.dropFirst(12 + length))
        try result.write(to: destination)
    }
}
