import CoreLocation
import Foundation
import SQLite3

struct RegionalPlaceIndex: Sendable {
    let file: URL

    struct Metadata: Equatable, Sendable {
        let region: String
        let source: URL
        let attribution: String
        let license: String
        let licenseURL: URL
        let dataVersion: String?
        let placeCount: Int
        let bounds: Bounds?
    }

    struct Bounds: Equatable, Sendable {
        let west: Double
        let south: Double
        let east: Double
        let north: Double

        func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
            guard CLLocationCoordinate2DIsValid(coordinate), (south...north).contains(coordinate.latitude) else {
                return false
            }
            if west <= east { return (west...east).contains(coordinate.longitude) }
            return coordinate.longitude >= west || coordinate.longitude <= east
        }
    }

    struct Place: Identifiable, Sendable {
        let id: Int64
        let name: String
        let category: String
        let categoryLabel: String
        let address: String
        let coordinate: CLLocationCoordinate2D
    }

    struct NearbyPlace: Identifiable, Sendable {
        let place: Place
        let distanceMeters: Double
        var id: Place.ID { place.id }
    }

    enum Category: String, CaseIterable, Identifiable, Sendable {
        case hospital, urgentCare = "urgent_care", pharmacy, police, fireStation = "fire_station"
        case shelter, gas, grocery, hardware, drinkingWater = "drinking_water"

        var id: String { rawValue }
    }

    enum IndexError: LocalizedError {
        case unreadable
        case unsupportedVersion
        case invalidMetadata

        var errorDescription: String? {
            switch self {
            case .unreadable: "The regional place index could not be read."
            case .unsupportedVersion: "This regional place index uses an unsupported format."
            case .invalidMetadata: "The regional place index is missing its dataset details."
            }
        }
    }

    func metadata() throws -> Metadata {
        try withDatabase { db in
            let values = try withStatement(db, "SELECT key, value FROM metadata") { statement in
                var fields: [String: String] = [:]
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    fields[Self.text(statement, 0)] = Self.text(statement, 1)
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else { throw IndexError.unreadable }
                return fields
            }
            guard let region = values["region"], !region.isEmpty,
                  let source = Self.webURL(values["source"]),
                  let attribution = values["attribution"], !attribution.isEmpty,
                  let license = values["license"], !license.isEmpty,
                  let licenseURL = Self.webURL(values["licenseURL"]),
                  let count = values["placeCount"].flatMap(Int.init), count > 0 else {
                throw IndexError.invalidMetadata
            }
            let bounds = try values["bounds"].map { value in
                let parts = value.split(separator: ",", omittingEmptySubsequences: false).compactMap { Double($0) }
                guard parts.count == 4, (-180...180).contains(parts[0]), (-180...180).contains(parts[2]),
                      parts[0] != parts[2], (-90...90).contains(parts[1]), (-90...90).contains(parts[3]),
                      parts[1] < parts[3] else { throw IndexError.invalidMetadata }
                return Bounds(west: parts[0], south: parts[1], east: parts[2], north: parts[3])
            }
            return Metadata(region: region, source: source, attribution: attribution, license: license,
                            licenseURL: licenseURL, dataVersion: values["dataVersion"], placeCount: count, bounds: bounds)
        }
    }

    func search(_ query: String, limit: Int = 40) throws -> [Place] {
        try search(query, limit: limit, destination: nil)
    }

    func destinations(matching question: HomeRouteQuestion, limit: Int) throws -> [Place] {
        try search(question.destination, limit: limit, destination: question)
    }

    private func search(_ query: String, limit: Int, destination: HomeRouteQuestion?) throws -> [Place] {
        let words = query.prefix(256).split { !$0.isLetter && !$0.isNumber }.prefix(12)
        guard !words.isEmpty, limit > 0 else { return [] }
        let expression = if let destination {
            "\(destination.isStreetAddress ? "address" : "title") : \"\(words.joined(separator: " "))\""
        } else {
            words.map { "\"\($0)\"*" }.joined(separator: " AND ")
        }
        let count = min(limit, 100)
        return try withDatabase { db in
            try withStatement(db, """
                SELECT p.id, p.title, p.category, p.category_words, p.address, p.latitude, p.longitude
                FROM place_search JOIN places AS p ON p.id = place_search.rowid
                WHERE place_search MATCH ?
                ORDER BY bm25(place_search, 4.0, 3.0, 1.0), p.id
                LIMIT ?
                """) { statement in
                try Self.bind(expression, at: 1, on: statement)
                guard sqlite3_bind_int(statement, 2, destination == nil ? Int32(count) : -1) == SQLITE_OK else {
                    throw IndexError.unreadable
                }
                var places: [Place] = []
                var status = sqlite3_step(statement)
                while status == SQLITE_ROW {
                    try Task.checkCancellation()
                    let place = try Self.place(statement)
                    let matches = destination.map {
                        $0.isStreetAddress ? $0.matchesAddress(place.address) : $0.matchesName(place.name)
                    } ?? true
                    if matches {
                        places.append(place)
                        if places.count == count { return places }
                    }
                    status = sqlite3_step(statement)
                }
                guard status == SQLITE_DONE else { throw IndexError.unreadable }
                return places
            }
        }
    }

    func nearest(_ category: Category, to origin: CLLocationCoordinate2D, radiusMeters: Double = 40_000,
                 limit: Int = 10) throws -> [NearbyPlace] {
        guard CLLocationCoordinate2DIsValid(origin), radiusMeters.isFinite,
              radiusMeters > 0, limit > 0 else { return [] }
        let radius = min(radiusMeters, 100_000)
        let count = min(limit, 100)
        let radians = Double.pi / 180
        let angularRadius = radius / Self.earthRadiusMeters
        let south = max(-90, origin.latitude - angularRadius / radians)
        let north = min(90, origin.latitude + angularRadius / radians)
        let longitudeRanges: [ClosedRange<Double>]
        if south == -90 || north == 90 {
            longitudeRanges = [-180...180]
        } else {
            let longitudeDelta = asin(min(1, sin(angularRadius) / cos(origin.latitude * radians))) / radians
            let west = origin.longitude - longitudeDelta
            let east = origin.longitude + longitudeDelta
            if west < -180 {
                longitudeRanges = [-180...east, (west + 360)...180]
            } else if east > 180 {
                longitudeRanges = [west...180, -180...(east - 360)]
            } else {
                longitudeRanges = [west...east]
            }
        }
        return try withDatabase { db in
            var results: [NearbyPlace] = []
            for longitudeRange in longitudeRanges {
                try withStatement(db, """
                    SELECT p.id, p.title, p.category, p.category_words, p.address, p.latitude, p.longitude
                    FROM place_bounds AS b JOIN places AS p ON p.id = b.id
                    WHERE b.max_latitude >= ? AND b.min_latitude <= ?
                      AND b.max_longitude >= ? AND b.min_longitude <= ? AND p.category = ?
                    """) { statement in
                    for (index, value) in [south, north, longitudeRange.lowerBound, longitudeRange.upperBound].enumerated() {
                        guard sqlite3_bind_double(statement, Int32(index + 1), value) == SQLITE_OK else {
                            throw IndexError.unreadable
                        }
                    }
                    try Self.bind(category.rawValue, at: 5, on: statement)
                    var status = sqlite3_step(statement)
                    while status == SQLITE_ROW {
                        try Task.checkCancellation()
                        let place = try Self.place(statement)
                        let distance = Self.distance(from: origin, to: place.coordinate)
                        if distance <= radius {
                            let insertion = results.firstIndex {
                                distance < $0.distanceMeters || (distance == $0.distanceMeters && place.id < $0.id)
                            } ?? results.endIndex
                            if insertion < count {
                                results.insert(NearbyPlace(place: place, distanceMeters: distance), at: insertion)
                                if results.count > count { results.removeLast() }
                            }
                        }
                        status = sqlite3_step(statement)
                    }
                    guard status == SQLITE_DONE else { throw IndexError.unreadable }
                }
            }
            return results
        }
    }

    private func withDatabase<T>(_ body: (OpaquePointer) throws -> T) throws -> T {
        guard file.isFileURL else { throw IndexError.unreadable }
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(file.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let database,
              sqlite3_exec(database, "PRAGMA trusted_schema = OFF", nil, nil, nil) == SQLITE_OK else {
            throw IndexError.unreadable
        }
        let identity = try withStatement(database, "PRAGMA application_id") { Self.readInteger($0) }
        let version = try withStatement(database, "PRAGMA user_version") { Self.readInteger($0) }
        guard identity == 0x54464B50, version == 1 else { throw IndexError.unsupportedVersion }
        return try body(database)
    }

    private func withStatement<T>(_ db: OpaquePointer, _ sql: String,
                                  _ body: (OpaquePointer) throws -> T) throws -> T {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw IndexError.unreadable
        }
        return try body(statement)
    }

    private static func readInteger(_ statement: OpaquePointer) -> Int32? {
        sqlite3_step(statement) == SQLITE_ROW ? sqlite3_column_int(statement, 0) : nil
    }

    private static func bind(_ text: String, at index: Int32, on statement: OpaquePointer) throws {
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, index, text, -1, transient) == SQLITE_OK else {
            throw IndexError.unreadable
        }
    }

    private static func text(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func place(_ statement: OpaquePointer) throws -> Place {
        let coordinate = CLLocationCoordinate2D(latitude: sqlite3_column_double(statement, 5),
                                                longitude: sqlite3_column_double(statement, 6))
        guard CLLocationCoordinate2DIsValid(coordinate) else { throw IndexError.unreadable }
        return Place(id: sqlite3_column_int64(statement, 0), name: text(statement, 1), category: text(statement, 2),
                     categoryLabel: text(statement, 3), address: text(statement, 4), coordinate: coordinate)
    }

    private static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", url.host != nil, url.user == nil else {
            return nil
        }
        return url
    }

    private static let earthRadiusMeters = 6_371_000.0

    private static func distance(from origin: CLLocationCoordinate2D, to target: CLLocationCoordinate2D) -> Double {
        let radians = Double.pi / 180
        let latitude = (target.latitude - origin.latitude) * radians
        let longitude = (target.longitude - origin.longitude) * radians
        let a = pow(sin(latitude / 2), 2)
            + cos(origin.latitude * radians) * cos(target.latitude * radians) * pow(sin(longitude / 2), 2)
        return earthRadiusMeters * 2 * asin(sqrt(min(1, max(0, a))))
    }
}
