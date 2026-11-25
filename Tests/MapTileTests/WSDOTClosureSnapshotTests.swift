import Foundation
import XCTest
@testable import TinfoilKit

final class WSDOTClosureSnapshotTests: XCTestCase {
    private let checkedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testEndpointUsesOfficialClosureLayerAndFixedBounds() throws {
        let endpoint = WSDOTClosureSnapshot.endpoint
        XCTAssertEqual(endpoint.scheme, "https")
        XCTAssertEqual(endpoint.host, "data.wsdot.wa.gov")
        XCTAssertTrue(endpoint.path.hasSuffix("/FeatureServer/2/query"))
        let query = try XCTUnwrap(URLComponents(url: endpoint, resolvingAgainstBaseURL: false)?.queryItems)
        let parameters = Dictionary(uniqueKeysWithValues: query.compactMap { item in
            item.value.map { (item.name, $0) }
        })
        XCTAssertEqual(parameters["geometry"], "-123.2,46.9,-121.2,48.25")
        XCTAssertEqual(parameters["where"], "RoadClosedFlag=1")
        XCTAssertEqual(parameters["outSR"], "4326")
        XCTAssertTrue(parameters["outFields"]?.contains("RoadClosedFlag") == true)
    }

    func testDecodesLineAndMultilineAndKeepsSourceTimestamp() throws {
        let snapshot = try decode([
            feature(id: 9),
            feature(id: 10, kind: "MultiLineString",
                    coordinates: [[[-122.25, 47.62], [-122.24, 47.62]], [[-122.23, 47.63], [-122.22, 47.64]]]),
            feature(id: 11, closed: 0)
        ])
        XCTAssertEqual(snapshot.closures.map(\.id), [9, 10])
        XCTAssertEqual(snapshot.closures[0].lines[0][0], point(47.6, -122.34))
        XCTAssertEqual(snapshot.closures[1].lines.count, 2)
        XCTAssertEqual(snapshot.closures[0].updatedAt, Date(timeIntervalSince1970: 1_794_267_630.627))
        XCTAssertEqual(snapshot.closures[0].road, "SR 116")
        XCTAssertEqual(snapshot.closures[0].direction, "Both Directions")
        let cached = try JSONDecoder().decode(WSDOTClosureSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(cached, snapshot)
        let date = checkedAt.addingTimeInterval(60)
        let revalidated = cached.revalidated(at: date, etag: nil, lastModified: "new")
        XCTAssertEqual(revalidated.checkedAt, date)
        XCTAssertEqual(revalidated.etag, "\"sample\"")
        XCTAssertEqual(revalidated.lastModified, "new")
        XCTAssertEqual(revalidated.closures, snapshot.closures)
    }

    func testEmptyIsCompleteOnlyWithoutTruncationOrServiceError() throws {
        XCTAssertTrue(try decode([]).closures.isEmpty)
        for fields in [
            ["exceededTransferLimit": true],
            ["properties": ["exceededTransferLimit": true]]
        ] as [[String: Any]] {
            XCTAssertThrowsError(try decode([], fields: fields)) {
                XCTAssertEqual($0 as? WSDOTClosureSnapshot.FeedError, .incomplete)
            }
        }
        let serviceError = Data(#"{"error":{"code":500,"message":"Unavailable"}}"#.utf8)
        XCTAssertThrowsError(try WSDOTClosureSnapshot.decode(serviceError, checkedAt: checkedAt,
                                                             etag: nil, lastModified: nil)) {
            XCTAssertEqual($0 as? WSDOTClosureSnapshot.FeedError, .invalidResponse)
        }
        XCTAssertThrowsError(try decode([], fields: ["error": ["code": 500]])) {
            XCTAssertEqual($0 as? WSDOTClosureSnapshot.FeedError, .invalidResponse)
        }
        XCTAssertThrowsError(try decode((1...2_000).map { feature(id: $0) })) {
            XCTAssertEqual($0 as? WSDOTClosureSnapshot.FeedError, .incomplete)
        }
    }

    func testRejectsWrongGeometryDuplicateIDsAndOversizedPayload() throws {
        for features in [
            [feature(id: 1, coordinates: [[-122.33, 47.6]])],
            [feature(id: 1, coordinates: [[-122.33, 47.6], [200, 47.6]])],
            [feature(id: 1, kind: "Point", coordinates: [-122.33, 47.6])],
            [feature(id: 1), feature(id: 1)]
        ] {
            XCTAssertThrowsError(try decode(features)) {
                XCTAssertEqual($0 as? WSDOTClosureSnapshot.FeedError, .invalidResponse)
            }
        }
        let oversized = Data(repeating: 32, count: WSDOTClosureSnapshot.maximumResponseBytes + 1)
        XCTAssertThrowsError(try WSDOTClosureSnapshot.decode(oversized, checkedAt: checkedAt, etag: nil,
                                                             lastModified: nil)) {
            XCTAssertEqual($0 as? WSDOTClosureSnapshot.FeedError, .responseTooLarge)
        }
    }

    func testAdvisoriesMatchCrossingsNearbyParallelAndEndpointProximity() throws {
        let snapshot = try decode([feature(id: 1)])
        let routes = [
            [point(47.59, -122.32), point(47.61, -122.32)],
            [point(47.60015, -122.33), point(47.60015, -122.31)],
            [point(47.6001, -122.29965), point(47.6001, -122.29)],
            [point(47.2, -122.32), point(48, -122.32)]
        ]
        for route in routes { XCTAssertEqual(snapshot.advisories(near: route).map(\.id), [1]) }
        XCTAssertTrue(snapshot.advisories(near: [point(47.6005, -122.33), point(47.6005, -122.31)]).isEmpty)
        XCTAssertTrue(snapshot.advisories(near: [point(47.59, -122.29), point(47.61, -122.29)]).isEmpty)
        XCTAssertTrue(snapshot.advisories(near: [point(47.6, -122.33)]).isEmpty)
        XCTAssertTrue(WSDOTClosureSnapshot.canMatch(route: routes[0]))
        XCTAssertFalse(WSDOTClosureSnapshot.canMatch(route: [point(35, -110), point(36, -111)]))
        let coarseRoute = (0..<258).map { point($0.isMultiple(of: 2) ? 47.2 : 48, -122.32) }
        XCTAssertFalse(WSDOTClosureSnapshot.canMatch(route: coarseRoute))
    }

    private func point(_ latitude: Double, _ longitude: Double) -> WSDOTCoordinate {
        .init(latitude: latitude, longitude: longitude)
    }

    private func feature(id: Int, closed: Int = 1, kind: String = "LineString",
                         coordinates: Any = [[-122.34, 47.6], [-122.30, 47.6]]) -> [String: Any] {
        [
            "type": "Feature",
            "properties": [
                "OBJECTID": id, "Road": "SR 116", "RoadDirection": "Both Directions",
                "HeadlineMessage": "Reported road closure", "LastModifiedDate": 1_794_267_630_627,
                "RoadClosedFlag": closed
            ],
            "geometry": ["type": kind, "coordinates": coordinates]
        ]
    }

    private func decode(_ features: [[String: Any]], fields: [String: Any] = [:]) throws -> WSDOTClosureSnapshot {
        var collection = fields
        collection["type"] = "FeatureCollection"
        collection["features"] = features
        return try WSDOTClosureSnapshot.decode(JSONSerialization.data(withJSONObject: collection),
                                               checkedAt: checkedAt, etag: "\"sample\"", lastModified: nil)
    }
}
