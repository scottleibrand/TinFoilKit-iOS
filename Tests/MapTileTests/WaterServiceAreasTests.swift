import Foundation
import XCTest
@testable import TinfoilKit

final class WaterServiceAreasTests: XCTestCase {
    func testRetainsOverlapsAndSharedEdgesInDeterministicOrder() throws {
        let publicationDate = "2026-03-06T14:09:01Z"
        let east = feature(id: "00101", name: "Alpha Water", coordinates: [
            rectangle(west: -122.31, south: 47.57, east: -122.24, north: 47.66)
        ])
        let west = feature(id: "AE050", name: "Beta Water", updatedAt: publicationDate, coordinates: [
            rectangle(west: -122.40, south: 47.57, east: -122.31, north: 47.66)
        ])
        let overlap = feature(id: "00202", name: "Alpha Water", coordinates: [
            rectangle(west: -122.36, south: 47.56, east: -122.29, north: 47.65)
        ])
        let areas = try makeAreas([west, overlap, east])

        let boundary = areas.providers(latitude: 47.6, longitude: -122.31)
        XCTAssertEqual(boundary.map(\.id), ["00101", "00202", "AE050"])
        XCTAssertEqual(boundary.last?.updatedAt, publicationDate)
        XCTAssertEqual(boundary.last?.county, "KING")
        XCTAssertEqual(areas.providers(latitude: 47.6, longitude: -122.35).map(\.id), ["00202", "AE050"])
        XCTAssertTrue(areas.providers(latitude: 47.6, longitude: -122.48).isEmpty)
        XCTAssertTrue(areas.providers(latitude: .nan, longitude: -122.31).isEmpty)
    }

    func testHoleInteriorIsExcludedAndItsBoundaryIsCovered() throws {
        let exterior = rectangle(west: -122.40, south: 47.55, east: -122.27, north: 47.65)
        let hole = rectangle(west: -122.36, south: 47.57, east: -122.32, north: 47.61)
        let areas = try makeAreas([feature(id: "01960", coordinates: [exterior, hole])])

        XCTAssertEqual(areas.providers(latitude: 47.59, longitude: -122.38).map(\.id), ["01960"])
        XCTAssertTrue(areas.providers(latitude: 47.59, longitude: -122.34).isEmpty)
        XCTAssertEqual(areas.providers(latitude: 47.59, longitude: -122.36).map(\.id), ["01960"])
        XCTAssertEqual(areas.providers(latitude: 47.57, longitude: -122.36).map(\.id), ["01960"])
        XCTAssertEqual(areas.providers(latitude: 47.55, longitude: -122.40).map(\.id), ["01960"])
    }

    func testDisjointMultiPolygonAndConsecutiveDuplicates() throws {
        var west = rectangle(west: -122.462, south: 47.55, east: -122.42, north: 47.61)
        west.insert(west[1], at: 1)
        let east = rectangle(west: -122.31, south: 47.55, east: -122.25, north: 47.61)
        let areas = try makeAreas([feature(id: "01300", geometry: "MultiPolygon", coordinates: [[west], [east]])])

        XCTAssertEqual(areas.providers(latitude: 47.58, longitude: -122.462).map(\.id), ["01300"])
        XCTAssertEqual(areas.providers(latitude: 47.58, longitude: -122.28).map(\.id), ["01300"])
        XCTAssertTrue(areas.providers(latitude: 47.58, longitude: -122.36).isEmpty)
        XCTAssertTrue(areas.providers(latitude: 47.58, longitude: -122.462001).isEmpty)
    }

    func testRejectsMalformedOrUnboundedGeometryAndDuplicateIdentifiers() throws {
        let valid = rectangle(west: -122.41, south: 47.55, east: -122.3, north: 47.65)
        let outside = rectangle(west: -122.51, south: 47.55, east: -122.42, north: 47.61)
        let crossing = [
            [-122.41, 47.55], [-122.30, 47.63], [-122.41, 47.65], [-122.33, 47.55], [-122.41, 47.55]
        ]
        let invalid: [[[String: Any]]] = [
            [feature(id: "001", coordinates: [valid])],
            [feature(id: "AB-01", coordinates: [valid])],
            [feature(id: "01173", coordinates: [Array(valid.dropLast())])],
            [feature(id: "01173", coordinates: [outside])],
            [feature(id: "01173", coordinates: [crossing])],
            [feature(id: "01173", coordinates: [valid, rectangle(west: -122.28, south: 47.57,
                                                                 east: -122.23, north: 47.60)])],
            [feature(id: "01173", geometry: "Point", coordinates: [-122.34, 47.59])],
            [feature(id: "01173", updatedAt: "invalid", coordinates: [valid])],
            [feature(id: "01173", coordinates: [valid]), feature(id: "01173", coordinates: [valid])]
        ]
        for features in invalid {
            XCTAssertThrowsError(try makeAreas(features)) {
                XCTAssertEqual($0 as? WaterServiceAreas.LoadError, .invalidDataset)
            }
        }
        XCTAssertThrowsError(try makeAreas([]))
        XCTAssertThrowsError(try makeAreas([feature(id: "01173", coordinates: [valid])], type: "Feature"))
    }

    func testCapsDataRecordsAndRawVertices() throws {
        XCTAssertThrowsError(try WaterServiceAreas(data: Data(repeating: 32, count: WaterServiceAreas.maxBytes + 1))) {
            XCTAssertEqual($0 as? WaterServiceAreas.LoadError, .sizeLimit)
        }
        let valid = feature(id: "01173", coordinates: [rectangle(west: -122.41, south: 47.55,
                                                                 east: -122.3, north: 47.65)])
        XCTAssertThrowsError(try makeAreas(Array(repeating: valid, count: 257))) {
            XCTAssertEqual($0 as? WaterServiceAreas.LoadError, .sizeLimit)
        }
        let many = Array(repeating: [-122.4, 47.59], count: 80_001)
        XCTAssertThrowsError(try makeAreas([feature(id: "01173", coordinates: [many])])) {
            XCTAssertEqual($0 as? WaterServiceAreas.LoadError, .sizeLimit)
        }
    }

    private func rectangle(west: Double, south: Double, east: Double, north: Double) -> [[Double]] {
        [[west, south], [east, south], [east, north], [west, north], [west, south]]
    }

    private func feature(id: String, name: String = "Fixture Water", updatedAt: String? = nil,
                         geometry: String = "Polygon", coordinates: Any) -> [String: Any] {
        var properties: [String: Any] = ["WS_ID": id, "WS_Name": name, "County": "KING"]
        if let updatedAt { properties["UpdateDateTime"] = updatedAt }
        return ["type": "Feature", "properties": properties,
                "geometry": ["type": geometry, "coordinates": coordinates]]
    }

    private func makeAreas(_ features: [[String: Any]], type: String = "FeatureCollection") throws -> WaterServiceAreas {
        let bytes = try JSONSerialization.data(withJSONObject: ["type": type, "features": features])
        return try WaterServiceAreas(data: bytes)
    }
}
