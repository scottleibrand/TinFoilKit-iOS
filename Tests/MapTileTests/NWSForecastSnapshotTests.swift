import Foundation
import XCTest
@testable import TinfoilKit

final class NWSForecastSnapshotTests: XCTestCase {
    private let dailyURL = "https://api.weather.gov/gridpoints/SEW/125,68/forecast"
    private let sourceTime = "2026-11-24T20:26:12+00:00"
    private let checkedAt = ISO8601DateFormatter().date(from: "2026-11-24T23:30:00Z")!

    func testSeattlePointURLsAndCacheRoundTrip() throws {
        let point = try NWSForecastPoint.decode(pointDocument(daily: dailyURL, hourly: dailyURL + "/hourly"),
                                                fetchedAt: checkedAt)
        XCTAssertEqual(point.url(for: .daily).absoluteString, dailyURL)
        XCTAssertEqual(point.url(for: .hourly).absoluteString, dailyURL + "/hourly")
        XCTAssertEqual(point.fetchedAt, checkedAt)
        XCTAssertEqual(point.timeZoneIdentifier, "America/Los_Angeles")
        let cached = try JSONDecoder().decode(NWSForecastPoint.self, from: JSONEncoder().encode(point))
        XCTAssertEqual(cached, point)
    }

    func testExplicitLocationUsesCanonicalCoordinatesFromAnywhere() throws {
        let portland = try XCTUnwrap(NWSForecastLocation(" 45.5231, -122.6765 "))
        XCTAssertEqual(portland.coordinates, "45.52,-122.68")
        XCTAssertEqual(portland.endpoint.absoluteString, "https://api.weather.gov/points/45.52,-122.68")
        XCTAssertEqual(NWSForecastLocation(portland.coordinates), portland)
        XCTAssertEqual(NWSForecastLocation("-0.001,0")?.coordinates, "0.00,0.00")
        for invalid in ["", "91,0", "0,-181", "nan,0", "1,inf", "1,2,3", "45,-122/path"] {
            XCTAssertNil(NWSForecastLocation(invalid), invalid)
        }
    }

    func testRejectsUntrustedOrMismatchedGridURLs() throws {
        let pairs = [
            ("http://api.weather.gov/gridpoints/SEW/125,68/forecast", dailyURL + "/hourly"),
            ("https://api.weather.gov.evil.invalid/gridpoints/SEW/125,68/forecast", dailyURL + "/hourly"),
            ("https://guest@api.weather.gov/gridpoints/SEW/125,68/forecast", dailyURL + "/hourly"),
            ("https://api.weather.gov:443/gridpoints/SEW/125,68/forecast", dailyURL + "/hourly"),
            (dailyURL + "?option=other", dailyURL + "/hourly"),
            (dailyURL + "#other", dailyURL + "/hourly"),
            (dailyURL.replacingOccurrences(of: "125,68", with: "125%2C68"), dailyURL + "/hourly"),
            (dailyURL, dailyURL.replacingOccurrences(of: "125,68", with: "124,68") + "/hourly"),
            (dailyURL, dailyURL),
            (dailyURL, dailyURL + "/hourly/")
        ]
        for (daily, hourly) in pairs {
            XCTAssertThrowsError(try NWSForecastPoint.decode(pointDocument(daily: daily, hourly: hourly),
                                                              fetchedAt: checkedAt), daily + " " + hourly)
        }
        let oversized = Data(repeating: 32, count: NWSForecastPoint.maxResponseBytes + 1)
        XCTAssertThrowsError(try NWSForecastPoint.decode(oversized, fetchedAt: checkedAt)) {
            XCTAssertEqual($0 as? NWSForecastError, .responseTooLarge)
        }
    }

    func testDailyAcceptsAnExpiredInitialPeriodAndKeepsThreeClocksSeparate() throws {
        let expires = checkedAt.addingTimeInterval(3_600)
        let daily = try NWSForecastSnapshot.decode(
            forecastDocument([
                period(id: 1, name: "This Afternoon", end: "2026-11-24T15:00:00-08:00"),
                period(id: 2, name: "Tonight", start: "2026-11-24T15:00:00-08:00", end: "2026-11-25T06:00:00-08:00")
            ]), kind: .daily, checkedAt: checkedAt, expiresAt: expires,
            etag: "\"daily\"", lastModified: "Tue, 24 Nov 2026 21:00:00 GMT"
        )
        XCTAssertEqual(daily.periods.map(\.id), [1, 2])
        XCTAssertLessThan(daily.periods[0].end, checkedAt)
        XCTAssertEqual(daily.periods[0].name, "This Afternoon")
        XCTAssertEqual(daily.periods[0].temperature, 52)
        XCTAssertEqual(daily.periods[0].temperatureUnit, "F")
        XCTAssertEqual(daily.periods[0].shortForecast, "Light Rain")
        XCTAssertEqual(daily.periods[0].detailedForecast, "Rain likely in the afternoon.")
        XCTAssertEqual(daily.sourceUpdatedAt, ISO8601DateFormatter().date(from: sourceTime))
        XCTAssertEqual(daily.checkedAt, checkedAt)
        XCTAssertEqual(daily.expiresAt, expires)
    }

    func testHourlyAcceptsBlankLabelAndDetailsAndRepeatedWallTime() throws {
        let hourly = try NWSForecastSnapshot.decode(
            forecastDocument([
                period(id: 1, name: "", start: "2026-11-01T01:00:00-07:00",
                       end: "2026-11-01T01:00:00-08:00", detailed: ""),
                period(id: 2, name: "", start: "2026-11-01T01:00:00-08:00",
                       end: "2026-11-01T02:00:00-08:00", detailed: nil)
            ]), kind: .hourly, checkedAt: checkedAt, expiresAt: nil, etag: nil, lastModified: nil
        )
        XCTAssertEqual(hourly.periods.count, 2)
        XCTAssertEqual(hourly.periods[0].name, "")
        XCTAssertNil(hourly.periods[0].detailedForecast)
        XCTAssertNil(hourly.periods[1].detailedForecast)
        XCTAssertEqual(hourly.periods[0].end.timeIntervalSince(hourly.periods[0].start), 3_600)
        XCTAssertEqual(hourly.periods[0].end, hourly.periods[1].start)
    }

    func testRevalidationPreservesPeriodAndSourceTimes() throws {
        let oldExpiry = checkedAt.addingTimeInterval(-60)
        let oldModified = "Tue, 24 Nov 2026 20:26:12 GMT"
        let snapshot = try NWSForecastSnapshot.decode(
            forecastDocument([period(id: 1)]), kind: .daily, checkedAt: checkedAt,
            expiresAt: oldExpiry, etag: "\"stable\"", lastModified: oldModified
        )
        let nextCheck = checkedAt.addingTimeInterval(60)
        let nextExpiry = nextCheck.addingTimeInterval(300)
        let updated = snapshot.revalidated(at: nextCheck, expiresAt: nextExpiry, etag: nil, lastModified: nil)
        XCTAssertEqual(updated.periods, snapshot.periods)
        XCTAssertEqual(updated.sourceUpdatedAt, snapshot.sourceUpdatedAt)
        XCTAssertEqual(updated.checkedAt, nextCheck)
        XCTAssertEqual(updated.expiresAt, nextExpiry)
        XCTAssertEqual(updated.etag, "\"stable\"")
        XCTAssertEqual(updated.lastModified, oldModified)
        let cached = try JSONDecoder().decode(NWSForecastSnapshot.self, from: JSONEncoder().encode(updated))
        XCTAssertEqual(cached, updated)
    }

    func testRejectsMissingOrMalformedForecastAndExcessiveData() throws {
        let invalid = try [
            forecastDocument([], updated: sourceTime),
            forecastDocument([period(id: 1)], updated: "unknown"),
            forecastDocument([period(id: 1)], updated: nil),
            forecastDocument([period(id: 1, end: "2026-11-24T13:00:00-08:00")]),
            forecastDocument([period(id: 1, end: "2026-11-24T15:00:00-08:00"),
                              period(id: 1, start: "2026-11-24T15:00:00-08:00")]),
            forecastDocument([period(id: 1, unit: "K")])
        ]
        for bytes in invalid {
            XCTAssertThrowsError(try NWSForecastSnapshot.decode(bytes, kind: .daily, checkedAt: checkedAt,
                                                               expiresAt: nil, etag: nil, lastModified: nil)) {
                XCTAssertEqual($0 as? NWSForecastError, .invalidResponse)
            }
        }
        let oversized = Data(repeating: 32, count: NWSForecastSnapshot.maxResponseBytes + 1)
        let tooMany = try forecastDocument((1...257).map { period(id: $0) })
        for bytes in [oversized, tooMany] {
            XCTAssertThrowsError(try NWSForecastSnapshot.decode(bytes, kind: .hourly, checkedAt: checkedAt,
                                                               expiresAt: nil, etag: nil, lastModified: nil)) {
                XCTAssertEqual($0 as? NWSForecastError, .responseTooLarge)
            }
        }
    }

    private func pointDocument(daily: String, hourly: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "type": "Feature",
            "geometry": NSNull(),
            "properties": ["forecast": daily, "forecastHourly": hourly, "timeZone": "America/Los_Angeles"]
        ])
    }

    private func forecastDocument(_ periods: [[String: Any]], updated: String? = "2026-11-24T20:26:12+00:00") throws -> Data {
        var properties: [String: Any] = ["generatedAt": "2026-11-24T23:00:00Z", "periods": periods]
        if let updated { properties["updateTime"] = updated }
        // The NWS point response supplies the grid URL. The presentation does not need forecast geometry.
        return try JSONSerialization.data(withJSONObject: ["type": "Feature", "geometry": NSNull(), "properties": properties])
    }

    private func period(id: Int, name: String = "Today", start: String = "2026-11-24T13:00:00-08:00",
                        end: String = "2026-11-24T16:00:00-08:00", detailed: String? = "Rain likely in the afternoon.",
                        unit: String = "F") -> [String: Any] {
        var result: [String: Any] = [
            "number": id, "name": name, "startTime": start, "endTime": end,
            "shortForecast": "Light Rain", "temperature": 52, "temperatureUnit": unit
        ]
        if let detailed { result["detailedForecast"] = detailed }
        return result
    }
}
