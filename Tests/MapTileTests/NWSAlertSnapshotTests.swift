import XCTest
@testable import TinfoilKit

final class NWSAlertSnapshotTests: XCTestCase {
    func testCompleteSnapshotKeepsZoneAlertsAndAppliesExplicitChanges() throws {
        let first = try decode([
            feature("old", kind: "Alert"),
            feature("current", kind: "Update", sent: "2026-11-24T10:05:00-08:00",
                    references: [reference("old")]),
            feature("cancelled", kind: "Alert"),
            feature("cancellation", kind: "Cancel", sent: "2026-11-24T10:10:00-08:00",
                    references: [reference("cancelled")], includeInfo: false),
            feature("test", kind: "Alert", status: "Test")
        ])
        XCTAssertEqual(first.alerts.map(\.id), [alertURL("current")])
        let alert = try XCTUnwrap(first.alerts.first)
        XCTAssertEqual(alert.areaDescription, "Test County")
        XCTAssertEqual(alert.expires.timeIntervalSince(alert.sent), 3_300)
        XCTAssertEqual(alert.sourceURL?.absoluteString, alertURL("current"))
        XCTAssertNotNil(first.sourceUpdatedAt)

        XCTAssertEqual(first.changes.map(\.kind), [.cancellation, .update])
        XCTAssertEqual(first.changes.map(\.affectedIDs), [[alertURL("cancelled")], [alertURL("old")]])
        XCTAssertEqual(first.changes.map(\.event), ["Flood Warning", "Flood Warning"])
        XCTAssertEqual(first.changes.map(\.areaDescription), ["Test County", "Test County"])
        XCTAssertEqual(first.changes.last?.sent, alert.sent)
        XCTAssertEqual(first.changes.first?.sourceURL?.absoluteString, alertURL("cancellation"))

        let check = first.checkedAt.addingTimeInterval(60)
        let revalidated = first.revalidated(at: check, etag: nil, lastModified: nil)
        XCTAssertEqual(revalidated.checkedAt, check)
        XCTAssertEqual(revalidated.sourceUpdatedAt, first.sourceUpdatedAt)
        XCTAssertEqual(revalidated.etag, first.etag)
        XCTAssertEqual(revalidated.alerts.first?.expires, first.alerts.first?.expires)
        XCTAssertEqual(revalidated.changes, first.changes)
    }

    func testShortOfficialReferenceLinkDoesNotSupersedeAlert() throws {
        var shortened = reference("old-full")
        shortened["@id"] = alertURL("old")
        let snapshot = try decode([
            feature("old-full", kind: "Alert"),
            feature("current", kind: "Update", sent: "2026-11-24T10:05:00-08:00",
                    references: [shortened, shortened])
        ])
        XCTAssertEqual(snapshot.alerts.map(\.id), [alertURL("current"), alertURL("old-full")])
        XCTAssertTrue(snapshot.changes.isEmpty)
    }

    func testIgnoresNonpublicUndatedAndUnrelatedCancellationRecords() throws {
        let later = "2026-11-24T10:05:00-08:00"
        var unrelated = reference("warning")
        unrelated["@id"] = "https://api.weather.gov.example/alerts/urn:oid:fixture-warning"
        let snapshot = try decode([
            feature("warning", kind: "Alert"),
            feature("test", kind: "Cancel", status: "Test", sent: later, references: [reference("warning")]),
            feature("private", kind: "Cancel", scope: "Restricted", sent: later, references: [reference("warning")]),
            feature("missing", kind: "Cancel", sent: later, includeInfo: false),
            feature("wrong-date", kind: "Cancel", sent: later,
                    references: [reference("warning", sent: "2026-11-24T09:59:00-08:00")], includeInfo: false),
            feature("equal-date", kind: "Cancel", sent: later,
                    references: [reference("absent", sent: later)], includeInfo: false),
            feature("malformed-date", kind: "Cancel", sent: "2026-11-24T10:05:00",
                    references: [reference("warning")], includeInfo: false),
            feature("future", kind: "Cancel", sent: "2030-01-01T00:00:00Z",
                    references: [reference("warning")], includeInfo: false),
            feature("off-origin", kind: "Cancel", sent: later, references: [unrelated], includeInfo: false)
        ])
        XCTAssertEqual(snapshot.alerts.map(\.id), [alertURL("warning")])
        XCTAssertTrue(snapshot.changes.isEmpty)
    }

    func testPartialCancellationOfAbsentAlertDoesNotInventAnActiveAlert() throws {
        let snapshot = try decode([
            feature("cancellation", kind: "Cancel", sent: "2026-11-24T10:15:00.25-08:00",
                    references: [reference("previous")], includeInfo: false)
        ])
        XCTAssertTrue(snapshot.alerts.isEmpty)
        let change = try XCTUnwrap(snapshot.changes.first)
        XCTAssertEqual(change.kind, .cancellation)
        XCTAssertEqual(change.affectedIDs, [alertURL("previous")])
        XCTAssertEqual(change.event, "Weather alert")
        XCTAssertEqual(change.areaDescription, "WA")
    }

    func testCacheIsScopedAndCompleteEmptyListReplacesOldAlertsWithoutInventingCancellation() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = NWSAlertCache(directory: directory)
        let initial = try decode([
            feature("warning", kind: "Alert"),
            feature("update", kind: "Update", sent: "2026-11-24T10:10:00-08:00",
                    references: [reference("warning")])
        ])
        try cache.write(initial)
        XCTAssertEqual(cache.read(area: "WA")?.alerts.map(\.id), [alertURL("update")])
        XCTAssertEqual(cache.read(area: "WA")?.changes, initial.changes)
        XCTAssertNil(cache.read(area: "OR"))
        XCTAssertNil(NWSAlertSnapshot.endpoint(for: "WA&point=0,0"))

        XCTAssertThrowsError(try decode([], next: "https://api.weather.gov/alerts/active?cursor=more"))
        XCTAssertThrowsError(try NWSAlertSnapshot.decode(Data(count: NWSAlertSnapshot.maximumResponseBytes + 1),
                                                         area: "WA", checkedAt: .now, etag: nil, lastModified: nil))
        XCTAssertEqual(cache.read(area: "WA")?.alerts.map(\.id), [alertURL("update")])
        try cache.write(try decode([]))
        XCTAssertEqual(cache.read(area: "WA")?.alerts.count, 0)
        XCTAssertTrue(cache.read(area: "WA")?.changes.isEmpty == true)
    }

    func testOlderCachedJSONDecodesWithoutChangeHistory() throws {
        let snapshot = try decode([feature("warning", kind: "Alert")])
        let fullData = try JSONEncoder().encode(snapshot)
        var previous = try XCTUnwrap(JSONSerialization.jsonObject(with: fullData) as? [String: Any])
        previous.removeValue(forKey: "changes")
        let restored = try JSONDecoder().decode(NWSAlertSnapshot.self,
                                               from: JSONSerialization.data(withJSONObject: previous))
        XCTAssertEqual(restored.alerts.map(\.id), [alertURL("warning")])
        XCTAssertTrue(restored.changes.isEmpty)
    }

    func testActiveRowsStillRequireCompleteVerifiedTimestamps() {
        XCTAssertThrowsError(try decode([feature("missing", kind: "Alert", includeInfo: false)]))
        XCTAssertThrowsError(try decode([feature("late", kind: "Alert", sent: "2026-11-24T11:10:00-08:00")]))
    }

    private let originalSent = "2026-11-24T10:00:00-08:00"

    private func decode(_ features: [[String: Any]], next: String? = nil) throws -> NWSAlertSnapshot {
        var collection: [String: Any] = ["type": "FeatureCollection", "features": features,
                                         "updated": "2026-11-24T18:00:00+00:00"]
        if let next { collection["pagination"] = ["next": next] }
        return try NWSAlertSnapshot.decode(JSONSerialization.data(withJSONObject: collection), area: "WA",
                                           checkedAt: Date(timeIntervalSince1970: 1_800_000_000), etag: "W/\"claim\"",
                                           lastModified: nil)
    }

    private func feature(_ id: String, kind: String, status: String = "Actual", scope: String = "Public",
                         sent: String? = nil, references: [[String: String]] = [], includeInfo: Bool = true) -> [String: Any] {
        var properties: [String: Any] = ["id": "urn:oid:fixture-\(id)", "status": status, "messageType": kind,
                                         "scope": scope, "sent": sent ?? originalSent, "references": references]
        if includeInfo {
            properties["event"] = "Flood Warning"
            properties["areaDesc"] = "Test County"
            properties["description"] = "Fixture warning."
            properties["expires"] = "2026-11-24T11:00:00-08:00"
        }
        return ["id": alertURL(id), "geometry": NSNull(), "properties": properties]
    }

    private func reference(_ id: String, sent: String? = nil) -> [String: String] {
        ["@id": alertURL(id), "identifier": "urn:oid:fixture-\(id)", "sent": sent ?? originalSent,
         "sender": "w-nws.webmaster@noaa.gov"]
    }

    private func alertURL(_ id: String) -> String {
        "https://api.weather.gov/alerts/urn:oid:fixture-\(id)"
    }
}
