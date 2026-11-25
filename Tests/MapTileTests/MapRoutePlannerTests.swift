import XCTest
@testable import TinfoilKit

final class MapRoutePlannerTests: XCTestCase {
    func testUsesDesktopCoordinateFormatsForEitherEndpoint() throws {
        let cases = [
            ("40.7128 N 74.0060 W", 40.7128, -74.006),
            ("40.7128N, 74.0060W", 40.7128, -74.006),
            ("74.006 W, 40.7128 N", 40.7128, -74.006),
            ("N 40° 42.768' W 74° 0.36'", 40.7128, -74.006),
            ("S 33.8688 E 151.2093", -33.8688, 151.2093),
            ("51.5074° N, 0.1278° W", 51.5074, -0.1278),
            ("40, -74", 40.0, -74.0),
        ]
        for (text, latitude, longitude) in cases {
            let result = try XCTUnwrap(MapCoordinateText.parse(text), text)
            XCTAssertEqual(result.latitude, latitude, accuracy: 0.000001, text)
            XCTAssertEqual(result.longitude, longitude, accuracy: 0.000001, text)
        }
        for text in ["45 N 100 W", "40.1 N 50.2 N", "-40.5 S, 10.1 E", "N 40° 60' W 74° 0'"] {
            XCTAssertNil(MapCoordinateText.parse(text), text)
        }
    }

    func testBothEndpointsMustBeInTheSameRoutingPack() {
        let west = RoutingPack.Bounds(west: -123, south: 47, east: -122, north: 48)
        let east = RoutingPack.Bounds(west: -122, south: 47, east: -121, north: 48)
        let origin = MapRoute.Point(latitude: 47.5, longitude: -122.5)
        let destination = MapRoute.Point(latitude: 47.5, longitude: -121.5)
        var draft = MapRouteDraft(origin: origin, destination: nil, mode: .driving)
        XCTAssertEqual(draft.availability(coverage: [west, east], walkingPreview: nil), .needsEndpoints)
        draft.destination = origin
        XCTAssertEqual(draft.availability(coverage: [west, east], walkingPreview: nil), .sameLocation)
        draft.destination = destination
        XCTAssertEqual(draft.availability(coverage: [west, east], walkingPreview: nil), .outsideCoverage)
        let combined = RoutingPack.Bounds(west: -123, south: 47, east: -121, north: 48)
        XCTAssertEqual(draft.availability(coverage: [west, east, combined], walkingPreview: nil), .ready)
    }

    func testWalkingPreviewDoesNotEnableDrivingOrOutOfAreaWalks() {
        let bounds = RoutingPack.Bounds(west: -123, south: 47, east: -122, north: 48)
        var draft = MapRouteDraft(origin: .init(latitude: 47.5, longitude: -122.5),
                                 destination: .init(latitude: 47.6, longitude: -122.5), mode: .driving)
        XCTAssertEqual(draft.availability(coverage: [], walkingPreview: bounds), .outsideCoverage)
        draft.mode = .walking
        XCTAssertEqual(draft.availability(coverage: [], walkingPreview: bounds), .ready)
        draft.destination = .init(latitude: 47.6, longitude: -121.5)
        XCTAssertEqual(draft.availability(coverage: [], walkingPreview: bounds), .outsideCoverage)
    }
}
