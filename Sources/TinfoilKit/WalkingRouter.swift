import CoreLocation
import Foundation
import SQLite3

struct WalkingRoute: Sendable {
    struct Point: Sendable {
        let latitude: Double
        let longitude: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }

        func distance(to other: Point) -> Double {
            let radians = Double.pi / 180
            let latitudeDelta = (other.latitude - latitude) * radians
            let longitudeDelta = (other.longitude - longitude) * radians
            let a = pow(sin(latitudeDelta / 2), 2)
                + cos(latitude * radians) * cos(other.latitude * radians) * pow(sin(longitudeDelta / 2), 2)
            return 12_742_000 * asin(sqrt(min(1, a)))
        }
    }

    let points: [Point]
    let meters: Double
}

struct WalkingRouter {
    let index: URL
    private static let precision = 10_000_000.0

    func route(from origin: WalkingRoute.Point, to destination: WalkingRoute.Point) throws -> WalkingRoute {
        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(index.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            throw RoutingError.unavailable
        }
        let start = try nearest(to: origin, on: db)
        let goal = try nearest(to: destination, on: db)
        guard start.id != goal.id else { throw RoutingError.tooClose }
        let sql = """
            SELECT nodes.id, nodes.latitude, nodes.longitude
            FROM edges INNER JOIN nodes ON nodes.id = edges.destination WHERE edges.origin = ?
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RoutingError.unavailable
        }

        var frontier = Frontier()
        frontier.push(Candidate(node: start, distance: 0, priority: start.point.distance(to: goal.point)))
        var distances: [Int64: Double] = [start.id: 0]
        var previous: [Int64: Node] = [:]
        while let candidate = frontier.pop() {
            try Task.checkCancellation()
            guard distances[candidate.node.id] == candidate.distance else { continue }
            if candidate.node.id == goal.id {
                var nodes = [goal.point]
                var current = goal.id
                while let parent = previous[current] {
                    nodes.append(parent.point)
                    current = parent.id
                }
                return WalkingRoute(points: nodes.reversed(), meters: candidate.distance)
            }
            guard sqlite3_bind_int64(statement, 1, candidate.node.id) == SQLITE_OK else {
                throw RoutingError.unavailable
            }
            var status = sqlite3_step(statement)
            while status == SQLITE_ROW {
                let neighbor = Self.node(from: statement)
                let distance = candidate.distance + candidate.node.point.distance(to: neighbor.point)
                if distance < distances[neighbor.id, default: .infinity] {
                    distances[neighbor.id] = distance
                    previous[neighbor.id] = candidate.node
                    frontier.push(Candidate(
                        node: neighbor,
                        distance: distance,
                        priority: distance + neighbor.point.distance(to: goal.point)
                    ))
                }
                status = sqlite3_step(statement)
            }
            guard status == SQLITE_DONE, sqlite3_reset(statement) == SQLITE_OK else {
                throw RoutingError.unavailable
            }
        }
        throw RoutingError.noRoute
    }

    private func nearest(to point: WalkingRoute.Point, on db: OpaquePointer) throws -> Node {
        let sql = """
            SELECT id, latitude, longitude FROM nodes
            WHERE latitude BETWEEN ? AND ? AND longitude BETWEEN ? AND ?
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw RoutingError.unavailable
        }
        let latitude = Int64(point.latitude * Self.precision)
        let longitude = Int64(point.longitude * Self.precision)
        sqlite3_bind_int64(statement, 1, latitude - 20_000)
        sqlite3_bind_int64(statement, 2, latitude + 20_000)
        sqlite3_bind_int64(statement, 3, longitude - 34_000)
        sqlite3_bind_int64(statement, 4, longitude + 34_000)
        var closest: Node?
        var best = 220.0
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            let node = Self.node(from: statement)
            let distance = node.point.distance(to: point)
            if distance < best {
                best = distance
                closest = node
            }
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw RoutingError.unavailable }
        guard let closest else { throw RoutingError.noNearbyPath }
        return closest
    }

    private static func node(from statement: OpaquePointer) -> Node {
        Node(
            id: sqlite3_column_int64(statement, 0),
            point: WalkingRoute.Point(
                latitude: Double(sqlite3_column_int64(statement, 1)) / precision,
                longitude: Double(sqlite3_column_int64(statement, 2)) / precision
            )
        )
    }

    private struct Node {
        let id: Int64
        let point: WalkingRoute.Point
    }

    private struct Candidate {
        let node: Node
        let distance: Double
        let priority: Double
    }

    private struct Frontier {
        private var candidates: [Candidate] = []

        mutating func push(_ candidate: Candidate) {
            candidates.append(candidate)
            var index = candidates.count - 1
            while index > 0 {
                let parent = (index - 1) / 2
                if candidates[parent].priority <= candidates[index].priority { break }
                candidates.swapAt(parent, index)
                index = parent
            }
        }

        mutating func pop() -> Candidate? {
            guard let next = candidates.first else { return nil }
            let last = candidates.removeLast()
            if !candidates.isEmpty {
                candidates[0] = last
                var index = 0
                while index * 2 + 1 < candidates.count {
                    let left = index * 2 + 1
                    let right = left + 1
                    let child = right < candidates.count && candidates[right].priority < candidates[left].priority
                        ? right : left
                    if candidates[index].priority <= candidates[child].priority { break }
                    candidates.swapAt(index, child)
                    index = child
                }
            }
            return next
        }
    }

    private enum RoutingError: LocalizedError {
        case unavailable, noNearbyPath, tooClose, noRoute

        var errorDescription: String? {
            switch self {
            case .unavailable: "The walking map is unavailable."
            case .noNearbyPath: "One of these places is too far from a mapped walking path."
            case .tooClose: "Both places are on the same point of the walking map."
            case .noRoute: "No walking route is available between these places in this region."
            }
        }
    }
}
