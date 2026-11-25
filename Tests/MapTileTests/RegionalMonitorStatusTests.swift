import Foundation
import XCTest
@testable import TinfoilKit

final class RegionalMonitorStatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testTimelineUsesOfficialDatesAndKeepsExplicitChangesAndExpiry() throws {
        let weather = try weatherSnapshot([
            alert("original", sent: -100),
            alert("update", kind: "Update", sent: -60, references: [("original", -100)]),
            alert("cancelled", sent: -120),
            alert("cancel", kind: "Cancel", sent: -80, references: [("cancelled", -120)]),
            alert("expired", sent: -200, expires: 0)
        ])
        let roads = try roadSnapshot([closure(1), closure(2, updated: -70), closure(3, updated: -60)])
        let status = RegionalMonitorStatus(area: "WA", weather: weather, roadClosures: roads, roadsEnabled: true, now: now)

        XCTAssertEqual(status.weatherStatus.coverage, .weatherArea("WA"))
        XCTAssertEqual(status.roadStatus.coverage, .pugetSoundPilot)
        XCTAssertEqual(status.weatherStatus.state, .saved(checkedAt: now, stale: false, count: 1))
        XCTAssertEqual(status.roadStatus.state, .saved(checkedAt: now, stale: false, count: 3))
        XCTAssertEqual(status.entries.map(\.id), [
            "nws:\(id("update"))", "wsdot:3", "wsdot:2", "nws:\(id("cancel"))", "nws:\(id("expired"))", "wsdot:1"
        ])
        XCTAssertEqual(status.entries.first?.alertChange?.kind, .update)
        XCTAssertEqual(status.entries.first?.date, now.addingTimeInterval(-60))
        XCTAssertEqual(status.entries.first?.expiresAt, now.addingTimeInterval(300))
        XCTAssertEqual(status.entries.first?.source, .weather)
        let cancellationEntry = try XCTUnwrap(status.entries.first { $0.id == "nws:\(id("cancel"))" })
        guard case let .change(cancellation) = cancellationEntry.kind else {
            return XCTFail("Expected the explicit cancellation")
        }
        XCTAssertEqual(cancellation.kind, .cancellation)
        XCTAssertNil(cancellationEntry.expiresAt)
        XCTAssertEqual(status.entries.first { $0.id == "nws:\(id("expired"))" }?.expiresAt, now)
        XCTAssertEqual(status.entries.last?.source, .roads)
        XCTAssertNil(status.entries.last?.date)
    }

    func testMissingDisabledOutOfScopeAndSavedZeroRemainDistinct() throws {
        let roads = try roadSnapshot([closure(1)])
        let washington = try weatherSnapshot([alert("warning", sent: -60)])
        let noArea = RegionalMonitorStatus(area: "", weather: washington, roadClosures: roads, roadsEnabled: true, now: now)
        XCTAssertEqual(noArea.weatherStatus.state, .noArea)
        XCTAssertEqual(noArea.weatherStatus.coverage, .weatherArea(nil))
        XCTAssertEqual(noArea.roadStatus.state, .outsideCoverage)
        XCTAssertTrue(noArea.entries.isEmpty)

        let oregon = RegionalMonitorStatus(area: "OR", weather: washington, roadClosures: roads, roadsEnabled: true, now: now)
        XCTAssertEqual(oregon.weatherStatus.state, .unchecked)
        XCTAssertEqual(oregon.roadStatus.state, .outsideCoverage)
        XCTAssertTrue(oregon.entries.isEmpty)

        let disabled = RegionalMonitorStatus(area: "WA", weather: nil, roadClosures: roads, roadsEnabled: false, now: now)
        XCTAssertEqual(disabled.roadStatus.state, .off)
        XCTAssertTrue(disabled.entries.isEmpty)

        let unavailable = RegionalMonitorStatus(area: "WA", weather: nil, roadClosures: nil, roadsEnabled: true, now: now)
        XCTAssertEqual(unavailable.roadStatus.state, .unchecked)

        let stale = now.addingTimeInterval(-1_800)
        let fresh = now.addingTimeInterval(-1_799)
        let zero = RegionalMonitorStatus(area: "WA", weather: try weatherSnapshot([], checkedAt: stale),
                                         roadClosures: try roadSnapshot([], checkedAt: fresh), roadsEnabled: true, now: now)
        XCTAssertEqual(zero.weatherStatus.state, .saved(checkedAt: stale, stale: true, count: 0))
        XCTAssertEqual(zero.roadStatus.state, .saved(checkedAt: fresh, stale: false, count: 0))
        XCTAssertTrue(zero.entries.isEmpty)
    }

    func testExpiredAlertsAndCancellationRemainVisibleWithZeroUnexpiredAlerts() throws {
        let weather = try weatherSnapshot([
            alert("expired", sent: -200, expires: 0),
            alert("cancel", kind: "Cancel", sent: -80, references: [("cancelled", -120)])
        ])
        let status = RegionalMonitorStatus(area: "WA", weather: weather, roadClosures: nil, roadsEnabled: false, now: now)
        XCTAssertEqual(status.weatherStatus.state, .saved(checkedAt: now, stale: false, count: 0))
        XCTAssertEqual(status.entries.map(\.id), ["nws:\(id("cancel"))", "nws:\(id("expired"))"])
    }

    func testSavedWeatherOutsideWashingtonHasIndependentCoverage() throws {
        let checkedAt = now.addingTimeInterval(-90)
        let weather = try weatherSnapshot([alert("oregon", sent: -100)], checkedAt: checkedAt, area: "OR")
        let roads = try roadSnapshot([closure(1)])
        let monitor = RegionalMonitorStatus(area: "OR", weather: weather, roadClosures: roads,
                                            roadsEnabled: true, now: now)

        XCTAssertEqual(monitor.weatherStatus.coverage, .weatherArea("OR"))
        XCTAssertEqual(monitor.weatherStatus.state, .saved(checkedAt: checkedAt, stale: false, count: 1))
        XCTAssertEqual(monitor.roadStatus.state, .outsideCoverage)
        XCTAssertEqual(monitor.entries.map(\.id), ["nws:\(id("oregon"))"])
    }

    private func identifier(_ name: String) -> String { "urn:oid:fixture-\(name)" }

    private func id(_ name: String) -> String { "https://api.weather.gov/alerts/\(identifier(name))" }

    private func alert(_ name: String, kind: String = "Alert", sent: TimeInterval,
                       expires: TimeInterval = 300, references: [(String, TimeInterval)] = []) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        let sender = "w-nws.webmaster@noaa.gov"
        return [
            "id": id(name), "type": "Feature", "geometry": NSNull(),
            "properties": [
                "id": identifier(name), "status": "Actual", "scope": "Public", "sender": sender,
                "messageType": kind, "event": "Flood Warning", "areaDesc": "Fixture County",
                "description": "Test warning.", "sent": iso.string(from: now.addingTimeInterval(sent)),
                "expires": iso.string(from: now.addingTimeInterval(expires)),
                "references": references.map { name, sent in
                    ["@id": id(name), "identifier": identifier(name), "sender": sender,
                     "sent": iso.string(from: now.addingTimeInterval(sent))]
                }
            ]
        ]
    }

    private func closure(_ id: Int, updated: TimeInterval? = nil) -> [String: Any] {
        var properties: [String: Any] = ["OBJECTID": id, "Road": "SR 116", "HeadlineMessage": "Fixture closure",
                                         "RoadClosedFlag": 1]
        if let updated {
            properties["LastModifiedDate"] = Int64(now.addingTimeInterval(updated).timeIntervalSince1970 * 1_000)
        }
        return ["type": "Feature", "properties": properties,
                "geometry": ["type": "LineString", "coordinates": [[-122.34, 47.6], [-122.3, 47.6]]]]
    }

    private func weatherSnapshot(_ features: [[String: Any]], checkedAt: Date? = nil,
                                 area: String = "WA") throws -> NWSAlertSnapshot {
        try NWSAlertSnapshot.decode(collection(features), area: area, checkedAt: checkedAt ?? now, etag: nil, lastModified: nil)
    }

    private func roadSnapshot(_ features: [[String: Any]], checkedAt: Date? = nil) throws -> WSDOTClosureSnapshot {
        try WSDOTClosureSnapshot.decode(collection(features), checkedAt: checkedAt ?? now, etag: nil, lastModified: nil)
    }

    private func collection(_ features: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
    }
}
