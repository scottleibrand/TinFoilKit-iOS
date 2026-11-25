import CoreLocation
import Foundation

enum MapTravelMode: String, CaseIterable, Identifiable, Sendable {
    case walking, driving

    var id: String { rawValue }
    var title: String { self == .walking ? "Walking" : "Driving" }
    var costing: String { self == .walking ? "pedestrian" : "auto" }
}

struct MapRouteDraft {
    var origin: MapRoute.Point?
    var destination: MapRoute.Point?
    var mode: MapTravelMode

    enum Availability: Equatable { case needsEndpoints, sameLocation, outsideCoverage, ready }

    func availability(coverage: [RoutingPack.Bounds], walkingPreview: RoutingPack.Bounds?) -> Availability {
        guard let origin, let destination,
              CLLocationCoordinate2DIsValid(origin.coordinate), CLLocationCoordinate2DIsValid(destination.coordinate) else {
            return .needsEndpoints
        }
        if origin.latitude == destination.latitude && origin.longitude == destination.longitude {
            return .sameLocation
        }
        if coverage.contains(where: { $0.contains(origin) && $0.contains(destination) }) {
            return .ready
        }
        if mode == .walking, let walkingPreview, walkingPreview.contains(origin), walkingPreview.contains(destination) {
            return .ready
        }
        return .outsideCoverage
    }
}

struct MapRoute: Sendable {
    struct Point: Codable, Sendable {
        let latitude: Double
        let longitude: Double
        var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
    }

    struct Step: Identifiable, Sendable {
        let id: Int
        let instruction: String
        let start: Point
        let meters: Double
    }

    let points: [Point]
    let steps: [Step]
    let meters: Double
    let seconds: Double?
}

enum RouteError: LocalizedError {
    case invalidPack, incompatiblePack, storage, engineUnavailable, outsideRegion, noRoute, invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidPack: "The routing pack is incomplete or its checksum does not match."
        case .incompatiblePack: "This routing pack was built for a different version of the routing engine."
        case .storage: "There isn’t enough free storage to install this routing pack."
        case .engineUnavailable: "The offline routing engine could not open this graph."
        case .outsideRegion: "Choose two locations covered by the same installed routing pack."
        case .noRoute: "No offline route was found between these locations."
        case .invalidResponse: "The offline routing engine returned an invalid route."
        }
    }
}
