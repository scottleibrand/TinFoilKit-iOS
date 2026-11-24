import CoreLocation
import Foundation

enum ValhallaRouteResponse {
    static func decode(_ data: Data) throws -> MapRoute {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let trip = response.trip else { throw RouteError.noRoute }
        guard trip.status == 0, !trip.legs.isEmpty, (0...).contains(trip.summary.length),
              (0...).contains(trip.summary.time) else { throw RouteError.invalidResponse }
        var points: [MapRoute.Point] = []
        var steps: [MapRoute.Step] = []
        for leg in trip.legs {
            let line = try decodePolyline(leg.shape)
            guard line.count >= 2 else { throw RouteError.invalidResponse }
            for maneuver in leg.maneuvers {
                guard line.indices.contains(maneuver.begin_shape_index),
                      (0...).contains(maneuver.length) else { throw RouteError.invalidResponse }
                steps.append(MapRoute.Step(id: steps.count, instruction: maneuver.instruction,
                                           start: line[maneuver.begin_shape_index], meters: maneuver.length * 1000))
            }
            points += line
        }
        return MapRoute(points: points, steps: steps, meters: trip.summary.length * 1000, seconds: trip.summary.time)
    }

    static func decodePolyline(_ shape: String) throws -> [MapRoute.Point] {
        var bytes = shape.utf8.makeIterator()
        var latitude = 0
        var longitude = 0
        var points: [MapRoute.Point] = []
        while let first = bytes.next() {
            latitude += try component(first, from: &bytes)
            guard let next = bytes.next() else { throw RouteError.invalidResponse }
            longitude += try component(next, from: &bytes)
            let point = MapRoute.Point(latitude: Double(latitude) / 1_000_000,
                                       longitude: Double(longitude) / 1_000_000)
            guard CLLocationCoordinate2DIsValid(point.coordinate) else { throw RouteError.invalidResponse }
            points.append(point)
        }
        return points
    }

    private static func component(_ first: UInt8, from iterator: inout String.UTF8View.Iterator) throws -> Int {
        var byte = first
        var value = 0
        for shift in stride(from: 0, through: 30, by: 5) {
            guard (63...126).contains(byte) else { break }
            let part = Int(byte - 63)
            value |= (part & 31) << shift
            if part & 32 == 0 {
                return value & 1 == 0 ? value >> 1 : ~(value >> 1)
            }
            guard let next = iterator.next() else { break }
            byte = next
        }
        throw RouteError.invalidResponse
    }

    private struct Response: Decodable {
        struct Trip: Decodable {
            struct Summary: Decodable { let length: Double; let time: Double }
            struct Leg: Decodable {
                struct Maneuver: Decodable {
                    let instruction: String
                    let begin_shape_index: Int
                    let length: Double
                }

                let shape: String
                let maneuvers: [Maneuver]
            }

            let status: Int
            let summary: Summary
            let legs: [Leg]
        }

        let trip: Trip?
    }
}
