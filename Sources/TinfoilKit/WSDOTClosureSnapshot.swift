import Foundation

struct WSDOTCoordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double

    fileprivate var isValid: Bool {
        (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

struct WSDOTClosure: Codable, Equatable, Identifiable, Sendable {
    let id: Int
    let road: String
    let direction: String?
    let headline: String
    let updatedAt: Date?
    let lines: [[WSDOTCoordinate]]
}

struct WSDOTClosureSnapshot: Codable, Equatable, Sendable {
    static let maximumResponseBytes = 1_048_576
    static let west = -123.2
    static let south = 46.9
    static let east = -121.2
    static let north = 48.25
    static let sourceURL = URL(string: "https://wsdot.com/Travel/Real-time/Map/")!
    static let endpoint: URL = {
        var url = URLComponents(string: "https://data.wsdot.wa.gov/arcgis/rest/services/TravelInformation/TravelInfoRoadAlerts/FeatureServer/2/query")!
        url.queryItems = [
            .init(name: "where", value: "RoadClosedFlag=1"),
            .init(name: "geometry", value: "\(west),\(south),\(east),\(north)"),
            .init(name: "geometryType", value: "esriGeometryEnvelope"),
            .init(name: "inSR", value: "4326"),
            .init(name: "outSR", value: "4326"),
            .init(name: "spatialRel", value: "esriSpatialRelIntersects"),
            .init(name: "outFields", value: "OBJECTID,Road,RoadDirection,HeadlineMessage,LastModifiedDate,RoadClosedFlag"),
            .init(name: "f", value: "geojson")
        ]
        return url.url!
    }()

    enum FeedError: LocalizedError, Equatable {
        case incomplete
        case invalidResponse
        case responseTooLarge

        var errorDescription: String? {
            switch self {
            case .incomplete: "WSDOT returned only part of the closure report."
            case .invalidResponse: "The WSDOT closure report could not be read."
            case .responseTooLarge: "The WSDOT closure report exceeded its size limit."
            }
        }
    }

    let checkedAt: Date
    let etag: String?
    let lastModified: String?
    let closures: [WSDOTClosure]

    // A query at the service's record limit might have been truncated, even without a flag.
    private static let serviceRecordLimit = 2_000
    private static let maximumVertices = 40_000

    private init(checkedAt: Date, etag: String?, lastModified: String?, closures: [WSDOTClosure]) {
        self.checkedAt = checkedAt
        self.etag = Self.header(etag)
        self.lastModified = Self.header(lastModified)
        self.closures = closures
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let checkedAt = try values.decode(Date.self, forKey: .checkedAt)
        let closures = try values.decode([WSDOTClosure].self, forKey: .closures)
        try Self.validate(closures, checkedAt: checkedAt)
        self.init(checkedAt: checkedAt, etag: try values.decodeIfPresent(String.self, forKey: .etag),
                  lastModified: try values.decodeIfPresent(String.self, forKey: .lastModified), closures: closures)
    }

    static func decode(_ data: Data, checkedAt: Date, etag: String?, lastModified: String?) throws -> Self {
        guard data.count <= maximumResponseBytes else { throw FeedError.responseTooLarge }
        guard let response = try? JSONDecoder().decode(ClosureCollection.self, from: data),
              response.type == "FeatureCollection", response.error == nil else { throw FeedError.invalidResponse }
        guard response.exceededTransferLimit != true, response.properties?.exceededTransferLimit != true,
              response.features.count < serviceRecordLimit else { throw FeedError.incomplete }
        let closures = try response.features.compactMap { try $0.closure() }
        try validate(closures, checkedAt: checkedAt)
        return Self(checkedAt: checkedAt, etag: etag, lastModified: lastModified, closures: closures)
    }

    func revalidated(at checkedAt: Date, etag: String?, lastModified: String?) -> Self {
        Self(checkedAt: checkedAt, etag: Self.header(etag) ?? self.etag,
             lastModified: Self.header(lastModified) ?? self.lastModified, closures: closures)
    }

    // The source describes road geometry, without a verified association to local routing edges.
    func advisories(near route: [WSDOTCoordinate]) -> [WSDOTClosure] {
        guard !closures.isEmpty, let segments = ClosureRouteIndex.localSegments(route),
              let localRoute = ClosureRouteIndex(segments) else { return [] }
        var matches: [WSDOTClosure] = []
        for closure in closures {
            guard !Task.isCancelled else { return [] }
            if closure.lines.contains(where: { line in
                zip(line, line.dropFirst()).contains { start, end in
                    !Task.isCancelled && localRoute.isNear(ClosureSegment(start, end))
                }
            }) { matches.append(closure) }
        }
        return Task.isCancelled ? [] : matches
    }

    static func canMatch(route: [WSDOTCoordinate]) -> Bool {
        ClosureRouteIndex.localSegments(route) != nil
    }

    private static func validate(_ closures: [WSDOTClosure], checkedAt: Date) throws {
        guard checkedAt.timeIntervalSinceReferenceDate.isFinite, closures.count < serviceRecordLimit else {
            throw FeedError.invalidResponse
        }
        var identifiers = Set<Int>()
        var vertices = 0
        var wideSegments = 0
        for closure in closures {
            guard closure.id > 0, identifiers.insert(closure.id).inserted,
                  text(closure.road, limit: 128) != nil, text(closure.headline, limit: 4_096) != nil,
                  closure.direction.map({ text($0, limit: 128) != nil }) ?? true,
                  closure.updatedAt?.timeIntervalSince1970.isFinite ?? true,
                  !closure.lines.isEmpty else { throw FeedError.invalidResponse }
            for line in closure.lines {
                guard line.count >= 2, line.count <= maximumVertices - vertices,
                      line.allSatisfy(\.isValid) else { throw FeedError.invalidResponse }
                vertices += line.count
                for (start, end) in zip(line, line.dropFirst()) where !ClosureSegment(start, end).isIndexable {
                    wideSegments += 1
                    guard wideSegments <= 128 else { throw FeedError.invalidResponse }
                }
            }
        }
    }

    private static func header(_ value: String?) -> String? {
        guard let value, (1...1_024).contains(value.utf8.count),
              value.utf8.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return value
    }

    private static func text(_ value: String, limit: Int) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= limit else { return nil }
        return trimmed
    }

    private struct ClosureCollection: Decodable {
        struct Properties: Decodable { let exceededTransferLimit: Bool? }
        struct ArcGISError: Decodable { let code: Int? }
        let type: String
        let error: ArcGISError?
        let exceededTransferLimit: Bool?
        let properties: Properties?
        let features: [ClosureFeature]
    }

    private struct ClosureFeature: Decodable {
        struct Properties: Decodable {
            let id: Int
            let road: String
            let direction: String?
            let headline: String
            let modified: Int64?
            let closed: Int

            enum CodingKeys: String, CodingKey {
                case id = "OBJECTID"
                case road = "Road"
                case direction = "RoadDirection"
                case headline = "HeadlineMessage"
                case modified = "LastModifiedDate"
                case closed = "RoadClosedFlag"
            }
        }

        struct Geometry: Decodable {
            let lines: [[[Double]]]

            enum CodingKeys: String, CodingKey { case type, coordinates }

            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                switch try values.decode(String.self, forKey: .type) {
                case "LineString": lines = [try values.decode([[Double]].self, forKey: .coordinates)]
                case "MultiLineString": lines = try values.decode([[[Double]]].self, forKey: .coordinates)
                default: throw FeedError.invalidResponse
                }
            }
        }

        let type: String
        let properties: Properties
        let geometry: Geometry

        func closure() throws -> WSDOTClosure? {
            guard type == "Feature", properties.closed == 0 || properties.closed == 1 else {
                throw FeedError.invalidResponse
            }
            guard properties.closed == 1 else { return nil }
            guard let road = WSDOTClosureSnapshot.text(properties.road, limit: 128),
                  let headline = WSDOTClosureSnapshot.text(properties.headline, limit: 4_096) else {
                throw FeedError.invalidResponse
            }
            let updatedAt = try properties.modified.map { milliseconds in
                guard (0...253_402_300_799_999).contains(milliseconds) else { throw FeedError.invalidResponse }
                return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
            }
            let lines = try geometry.lines.map { line in
                try line.map { position in
                    guard position.count == 2 else { throw FeedError.invalidResponse }
                    return WSDOTCoordinate(latitude: position[1], longitude: position[0])
                }
            }
            let direction = properties.direction.flatMap { WSDOTClosureSnapshot.text($0, limit: 128) }
            return WSDOTClosure(id: properties.id, road: road, direction: direction, headline: headline,
                                updatedAt: updatedAt, lines: lines)
        }
    }
}

private struct ClosureRouteIndex {
    private static let distance = 40.0
    private let segments: [ClosureSegment]
    private var buckets: [ClosureCell: [Int]] = [:]
    private var longSegments: [ClosureSegment] = []

    static func localSegments(_ route: [WSDOTCoordinate]) -> [ClosureSegment]? {
        guard (2...50_000).contains(route.count) else { return nil }
        let southwest = WSDOTCoordinate(latitude: WSDOTClosureSnapshot.south, longitude: WSDOTClosureSnapshot.west)
        let northeast = WSDOTCoordinate(latitude: WSDOTClosureSnapshot.north, longitude: WSDOTClosureSnapshot.east)
        let coverage = ClosureSegment(southwest, northeast)
        var result: [ClosureSegment] = []
        var wideSegments = 0
        for (start, end) in zip(route, route.dropFirst()) {
            guard !Task.isCancelled, start.isValid, end.isValid else { return nil }
            guard abs(start.longitude - end.longitude) <= 180 else { continue }
            let segment = ClosureSegment(start, end)
            guard segment.boundsAreNear(coverage, distance: Self.distance) else { continue }
            if !segment.isIndexable {
                wideSegments += 1
                guard wideSegments <= 256 else { return nil }
            }
            result.append(segment)
        }
        return result.isEmpty ? nil : result
    }

    init?(_ segments: [ClosureSegment]) {
        self.segments = segments
        for (index, segment) in segments.enumerated() {
            guard !Task.isCancelled else { return nil }
            if let cells = segment.cells() {
                for cell in cells { buckets[cell, default: []].append(index) }
            } else {
                longSegments.append(segment)
            }
        }
    }

    func isNear(_ closure: ClosureSegment) -> Bool {
        guard let cells = closure.cells(padding: Self.distance) else {
            return segments.contains { !Task.isCancelled && $0.isNear(closure, distance: Self.distance) }
        }
        return longSegments.contains { !Task.isCancelled && $0.isNear(closure, distance: Self.distance) }
            || cells.contains { cell in
                buckets[cell]?.contains { !Task.isCancelled && segments[$0].isNear(closure, distance: Self.distance) }
                    == true
            }
    }
}

private struct ClosureCell: Hashable {
    let x: Int
    let y: Int
}

private struct ClosureSegment {
    private struct Point {
        let x: Double
        let y: Double

        init(_ coordinate: WSDOTCoordinate) {
            let latitude = (WSDOTClosureSnapshot.south + WSDOTClosureSnapshot.north) / 2
            let longitude = (WSDOTClosureSnapshot.west + WSDOTClosureSnapshot.east) / 2
            x = (coordinate.longitude - longitude) * (111_195 * cos(latitude * .pi / 180))
            y = (coordinate.latitude - latitude) * 111_195
        }
    }

    private let start: Point
    private let end: Point
    private let minX: Double
    private let maxX: Double
    private let minY: Double
    private let maxY: Double

    init(_ start: WSDOTCoordinate, _ end: WSDOTCoordinate) {
        self.start = Point(start)
        self.end = Point(end)
        minX = min(self.start.x, self.end.x)
        maxX = max(self.start.x, self.end.x)
        minY = min(self.start.y, self.end.y)
        maxY = max(self.start.y, self.end.y)
    }

    private func cellRanges(padding: Double) -> (x: ClosedRange<Int>, y: ClosedRange<Int>) {
        let left = Int(floor((minX - padding) / 512))
        let right = Int(floor((maxX + padding) / 512))
        let bottom = Int(floor((minY - padding) / 512))
        let top = Int(floor((maxY + padding) / 512))
        return (left...right, bottom...top)
    }

    var isIndexable: Bool {
        let ranges = cellRanges(padding: 0)
        return ranges.x.count * ranges.y.count <= 64
    }

    func cells(padding: Double = 0) -> [ClosureCell]? {
        let ranges = cellRanges(padding: padding)
        guard ranges.x.count * ranges.y.count <= 64 else { return nil }
        return ranges.x.flatMap { x in ranges.y.map { ClosureCell(x: x, y: $0) } }
    }

    func boundsAreNear(_ other: Self, distance: Double) -> Bool {
        minX <= other.maxX + distance && other.minX <= maxX + distance
            && minY <= other.maxY + distance && other.minY <= maxY + distance
    }

    func isNear(_ other: Self, distance: Double) -> Bool {
        guard boundsAreNear(other, distance: distance) else { return false }
        if boundsAreNear(other, distance: 0), straddles(other), other.straddles(self) { return true }
        let limit = distance * distance
        return squaredDistance(from: other.start) <= limit || squaredDistance(from: other.end) <= limit
            || other.squaredDistance(from: start) <= limit || other.squaredDistance(from: end) <= limit
    }

    private func straddles(_ other: Self) -> Bool {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let first = dx * (other.start.y - start.y) - dy * (other.start.x - start.x)
        let second = dx * (other.end.y - start.y) - dy * (other.end.x - start.x)
        return (first <= 0 && second >= 0) || (second <= 0 && first >= 0)
    }

    private func squaredDistance(from point: Point) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let squaredLength = dx * dx + dy * dy
        let projection = (point.x - start.x) * dx + (point.y - start.y) * dy
        let fraction = squaredLength > 0 ? min(1, max(0, projection / squaredLength)) : 0
        let x = point.x - (start.x + fraction * dx)
        let y = point.y - (start.y + fraction * dy)
        return x * x + y * y
    }
}
