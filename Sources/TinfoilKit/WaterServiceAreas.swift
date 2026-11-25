import Foundation

struct WaterServiceProvider: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
    let county: String
    let updatedAt: String?
}

struct WaterServiceAreas: Sendable {
    struct Bounds: Equatable, Sendable {
        let west: Double
        let south: Double
        let east: Double
        let north: Double

        func contains(latitude: Double, longitude: Double) -> Bool {
            (west...east).contains(longitude) && (south...north).contains(latitude)
        }

        fileprivate func contains(_ point: Point) -> Bool {
            contains(latitude: point.latitude, longitude: point.longitude)
        }
    }

    enum LoadError: LocalizedError, Equatable {
        case sizeLimit
        case invalidDataset

        var errorDescription: String? {
            switch self {
            case .sizeLimit: "The water service area file exceeds its limits."
            case .invalidDataset: "The water service area file contains invalid records or boundaries."
            }
        }
    }

    static let bounds = Bounds(west: -122.462, south: 47.394, east: -122.005, north: 47.831)
    static let maxBytes = 2 * 1024 * 1024
    private static let maxRecords = 256
    private static let maxVertices = 80_000
    private let records: [Record]

    init(data: Data) throws {
        guard data.count <= Self.maxBytes else { throw LoadError.sizeLimit }
        guard let collection = try? JSONDecoder().decode(FeatureCollection.self, from: data),
              collection.type == "FeatureCollection", !collection.features.isEmpty else {
            throw LoadError.invalidDataset
        }
        guard collection.features.count <= Self.maxRecords else { throw LoadError.sizeLimit }

        var ids = Set<String>()
        var remainingVertices = Self.maxVertices
        var intersectionChecks = 2_000_000
        let timestamp = ISO8601DateFormatter()
        let fractionalTimestamp = ISO8601DateFormatter()
        fractionalTimestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        records = try collection.features.map { feature in
            let properties = feature.properties
            let id = properties.id
            guard feature.type == "Feature", id.utf8.count == 5,
                  id.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) }),
                  ids.insert(id).inserted,
                  let name = Self.label(properties.name, maximumBytes: 256),
                  let county = Self.label(properties.county, maximumBytes: 128),
                  !feature.geometry.polygons.isEmpty else { throw LoadError.invalidDataset }
            if let update = properties.updatedAt {
                guard update.utf8.count <= 64,
                      timestamp.date(from: update) != nil || fractionalTimestamp.date(from: update) != nil else {
                    throw LoadError.invalidDataset
                }
            }
            let polygons = try feature.geometry.polygons.map {
                try Polygon($0, remainingVertices: &remainingVertices, intersectionChecks: &intersectionChecks)
            }
            let provider = WaterServiceProvider(id: id, name: name, county: county, updatedAt: properties.updatedAt)
            return Record(provider: provider, polygons: polygons)
        }.sorted {
            ($0.provider.name.lowercased(), $0.provider.id) < ($1.provider.name.lowercased(), $1.provider.id)
        }
    }

    func providers(latitude: Double, longitude: Double) -> [WaterServiceProvider] {
        let point = Point(longitude: longitude, latitude: latitude)
        guard Self.bounds.contains(point) else { return [] }
        return records.compactMap { record in
            record.polygons.contains { $0.covers(point) } ? record.provider : nil
        }
    }

    private static func label(_ text: String, maximumBytes: Int) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumBytes,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }

    private struct Record: Sendable {
        let provider: WaterServiceProvider
        let polygons: [Polygon]
    }

    fileprivate struct Point: Hashable, Sendable {
        let longitude: Double
        let latitude: Double
    }

    private enum Location: Equatable { case outside, inside, boundary }

    private struct Polygon: Sendable {
        let exterior: Ring
        let holes: [Ring]

        init(_ coordinates: [[[Double]]], remainingVertices: inout Int, intersectionChecks: inout Int) throws {
            guard !coordinates.isEmpty else { throw LoadError.invalidDataset }
            guard coordinates.count <= 128 else { throw LoadError.sizeLimit }
            let rings = try coordinates.map { try Ring($0, remainingVertices: &remainingVertices) }
            let shell = rings[0]
            let holes = Array(rings.dropFirst())
            try Self.validateEdges(rings, remainingChecks: &intersectionChecks)
            for (index, hole) in holes.enumerated() {
                guard shell.location(of: hole.points[0]) == .inside,
                      holes[..<index].allSatisfy({
                          $0.location(of: hole.points[0]) == .outside && hole.location(of: $0.points[0]) == .outside
                      }) else { throw LoadError.invalidDataset }
            }
            exterior = shell
            self.holes = holes
        }

        func covers(_ point: Point) -> Bool {
            switch exterior.location(of: point) {
            case .outside: false
            case .boundary: true
            case .inside: !holes.contains { $0.location(of: point) == .inside }
            }
        }

        private static func validateEdges(_ rings: [Ring], remainingChecks: inout Int) throws {
            let edges = rings.enumerated().flatMap { ringIndex, ring in
                ring.points.indices.map { index in
                    Edge(ringIndex: ringIndex, index: index, ringLength: ring.points.count,
                         start: ring.points[index], end: ring.points[(index + 1) % ring.points.count])
                }
            }.sorted { $0.bounds.west < $1.bounds.west }
            for index in edges.indices {
                let edge = edges[index]
                var next = index + 1
                while next < edges.count, edges[next].bounds.west <= edge.bounds.east {
                    guard remainingChecks > 0 else { throw LoadError.sizeLimit }
                    remainingChecks -= 1
                    let candidate = edges[next]
                    if !edge.adjacent(to: candidate), edge.intersects(candidate) { throw LoadError.invalidDataset }
                    next += 1
                }
            }
        }
    }

    private struct Ring: Sendable {
        let points: [Point]
        let bounds: Bounds

        init(_ coordinates: [[Double]], remainingVertices: inout Int) throws {
            guard coordinates.count <= remainingVertices else { throw LoadError.sizeLimit }
            remainingVertices -= coordinates.count
            guard coordinates.count >= 4, coordinates.first == coordinates.last else { throw LoadError.invalidDataset }

            var points: [Point] = []
            for coordinate in coordinates {
                guard coordinate.count == 2 else { throw LoadError.invalidDataset }
                let point = Point(longitude: coordinate[0], latitude: coordinate[1])
                guard WaterServiceAreas.bounds.contains(point) else { throw LoadError.invalidDataset }
                // Clipping and decimal rounding can emit repeated consecutive vertices.
                if point != points.last { points.append(point) }
            }
            guard points.count >= 4 else { throw LoadError.invalidDataset }
            points.removeLast()
            guard Set(points).count == points.count else { throw LoadError.invalidDataset }

            let origin = points[0]
            var area = 0.0
            var west = origin.longitude
            var south = origin.latitude
            var east = west
            var north = south
            for index in points.indices {
                let current = points[index]
                let next = points[(index + 1) % points.count]
                area += Self.signedProducts(origin, current, next).difference
                west = min(west, current.longitude)
                south = min(south, current.latitude)
                east = max(east, current.longitude)
                north = max(north, current.latitude)
            }
            guard area != 0 else { throw LoadError.invalidDataset }
            self.points = points
            bounds = Bounds(west: west, south: south, east: east, north: north)
        }

        static func side(_ start: Point, _ end: Point, _ test: Point) -> Int {
            let products = signedProducts(start, end, test)
            if abs(products.difference) <= products.magnitude * 8 * Double.ulpOfOne { return 0 }
            return products.difference > 0 ? 1 : -1
        }

        private static func signedProducts(_ start: Point, _ end: Point, _ test: Point)
            -> (difference: Double, magnitude: Double) {
            let left = (end.longitude - start.longitude) * (test.latitude - start.latitude)
            let right = (end.latitude - start.latitude) * (test.longitude - start.longitude)
            return (left - right, abs(left) + abs(right))
        }

        func location(of point: Point) -> Location {
            guard bounds.contains(point) else { return .outside }
            var inside = false
            var previous = points[points.count - 1]
            for current in points {
                if (min(previous.latitude, current.latitude)...max(previous.latitude, current.latitude)).contains(point.latitude),
                   (min(previous.longitude, current.longitude)...max(previous.longitude, current.longitude)).contains(point.longitude),
                   Self.side(previous, current, point) == 0 { return .boundary }
                if (previous.latitude > point.latitude) != (current.latitude > point.latitude) {
                    let fraction = (point.latitude - previous.latitude) / (current.latitude - previous.latitude)
                    if point.longitude < previous.longitude + fraction * (current.longitude - previous.longitude) {
                        inside.toggle()
                    }
                }
                previous = current
            }
            return inside ? .inside : .outside
        }
    }

    private struct Edge {
        let ringIndex: Int
        let index: Int
        let ringLength: Int
        let start: Point
        let end: Point
        var bounds: Bounds {
            Bounds(west: min(start.longitude, end.longitude), south: min(start.latitude, end.latitude),
                   east: max(start.longitude, end.longitude), north: max(start.latitude, end.latitude))
        }

        func adjacent(to other: Edge) -> Bool {
            let gap = abs(index - other.index)
            return ringIndex == other.ringIndex && (gap == 1 || gap == ringLength - 1)
        }

        func intersects(_ other: Edge) -> Bool {
            guard bounds.south <= other.bounds.north, other.bounds.south <= bounds.north else { return false }
            return Ring.side(start, end, other.start) * Ring.side(start, end, other.end) <= 0
                && Ring.side(other.start, other.end, start) * Ring.side(other.start, other.end, end) <= 0
        }
    }

    private struct FeatureCollection: Decodable {
        let type: String
        let features: [Feature]
    }

    private struct Feature: Decodable {
        struct Properties: Decodable {
            let id: String
            let name: String
            let county: String
            let updatedAt: String?

            enum CodingKeys: String, CodingKey {
                case id = "WS_ID"
                case name = "WS_Name"
                case county = "County"
                case updatedAt = "UpdateDateTime"
            }
        }

        struct Geometry: Decodable {
            let polygons: [[[[Double]]]]

            enum CodingKeys: String, CodingKey { case type, coordinates }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                switch try values.decode(String.self, forKey: .type) {
                case "Polygon": polygons = [try values.decode([[[Double]]].self, forKey: .coordinates)]
                case "MultiPolygon": polygons = try values.decode([[[[Double]]]].self, forKey: .coordinates)
                default: throw LoadError.invalidDataset
                }
            }
        }

        let type: String
        let properties: Properties
        let geometry: Geometry
    }
}
