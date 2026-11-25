import CryptoKit
import Foundation
import XCTest
@testable import TinfoilKit

final class WaterServiceAreaStoreTests: XCTestCase {
    func testRejectsAnUnpinnedReplacementAndReopensTheVerifiedFile() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("candidate.geojson")
        let installation = directory.appendingPathComponent("installed")
        let fixture = Data("""
            {"type":"FeatureCollection","features":[{"type":"Feature",
            "properties":{"WS_ID":"12345","WS_Name":"Fixture Water","County":"King",
            "UpdateDateTime":null,"DataSourceDate":null},
            "geometry":{"type":"Polygon","coordinates":[[[-122.4,47.5],[-122.3,47.5],
            [-122.3,47.6],[-122.4,47.6],[-122.4,47.5]]]}}]}
            """.utf8)
        let digest = SHA256.hash(data: fixture).map { String(format: "%02x", $0) }.joined()
        try fixture.write(to: source)

        let store = WaterServiceAreaStore(directory: installation, expectedSHA256: digest)
        try await store.install(from: source)
        let first = try await store.providers(latitude: 47.55, longitude: -122.35)
        XCTAssertEqual(first.map(\.id), ["12345"])

        try (fixture + Data(" ".utf8)).write(to: source)
        do {
            try await store.install(from: source)
            XCTFail("An unpinned file must not replace the verified edition")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("verified Seattle water service area edition"))
        }

        let reopened = WaterServiceAreaStore(directory: installation, expectedSHA256: digest)
        let saved = try await reopened.providers(latitude: 47.55, longitude: -122.35)
        XCTAssertEqual(saved.map(\.id), first.map(\.id))
        try await reopened.remove()
        let installed = await reopened.isInstalled()
        XCTAssertFalse(installed)
    }
}
