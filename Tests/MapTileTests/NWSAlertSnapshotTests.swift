import XCTest
@testable import TinfoilKit

final class NWSAlertSnapshotTests: XCTestCase {
    func testCompleteSnapshotKeepsZoneAlertsAndAppliesUpdatesAndCancellation() throws {
        let first = try decode([
            feature("old", kind: "Alert"),
            feature("current", kind: "Update", references: ["old"]),
            feature("cancelled", kind: "Alert"),
            feature("cancellation", kind: "Cancel", references: ["cancelled"]),
            feature("test", kind: "Alert", status: "Test")
        ])
        XCTAssertEqual(first.alerts.map(\.id), ["current"])
        let alert = try XCTUnwrap(first.alerts.first)
        XCTAssertEqual(alert.areaDescription, "Test County")
        XCTAssertEqual(alert.expires.timeIntervalSince(alert.sent), 3_600)
        XCTAssertNotNil(first.sourceUpdatedAt)
        let check = first.checkedAt.addingTimeInterval(60)
        let revalidated = first.revalidated(at: check, etag: nil, lastModified: nil)
        XCTAssertEqual(revalidated.checkedAt, check)
        XCTAssertEqual(revalidated.sourceUpdatedAt, first.sourceUpdatedAt)
        XCTAssertEqual(revalidated.etag, first.etag)
        XCTAssertEqual(revalidated.alerts.first?.expires, first.alerts.first?.expires)
    }

    func testCacheIsScopedAndCompleteEmptyListReplacesOldAlerts() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NWSAlertCache(directory: directory)
        let initial = try decode([feature("warning", kind: "Alert")])
        try cache.write(initial)
        XCTAssertEqual(cache.read(area: "WA")?.alerts.map(\.id), ["warning"])
        XCTAssertNil(cache.read(area: "OR"))
        XCTAssertNil(NWSAlertSnapshot.endpoint(for: "WA&point=0,0"))

        XCTAssertThrowsError(try decode([], next: "https://api.weather.gov/alerts/active?cursor=more"))
        XCTAssertThrowsError(try NWSAlertSnapshot.decode(Data(count: NWSAlertSnapshot.maximumResponseBytes + 1),
                                                         area: "WA", checkedAt: .now, etag: nil, lastModified: nil))
        XCTAssertEqual(cache.read(area: "WA")?.alerts.map(\.id), ["warning"])
        try cache.write(try decode([]))
        XCTAssertEqual(cache.read(area: "WA")?.alerts.count, 0)
    }

    private func decode(_ features: [[String: Any]], next: String? = nil) throws -> NWSAlertSnapshot {
        var collection: [String: Any] = ["type": "FeatureCollection", "features": features,
                                         "updated": "2026-11-24T18:00:00+00:00"]
        if let next { collection["pagination"] = ["next": next] }
        return try NWSAlertSnapshot.decode(JSONSerialization.data(withJSONObject: collection), area: "WA",
                                           checkedAt: Date(timeIntervalSince1970: 1_800_000_000), etag: "W/\"claim\"",
                                           lastModified: nil)
    }

    private func feature(_ id: String, kind: String, status: String = "Actual", references: [String] = []) -> [String: Any] {
        ["id": id, "geometry": NSNull(), "properties": ["event": "Flood Warning", "status": status,
          "messageType": kind, "areaDesc": "Test County", "description": "Fixture warning.",
          "sent": "2026-11-24T10:00:00-08:00", "expires": "2026-11-24T11:00:00-08:00",
          "references": references.map { ["@id": $0] }]]
    }
}
