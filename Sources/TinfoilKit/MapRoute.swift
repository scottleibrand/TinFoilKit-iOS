import CoreLocation
import Foundation

enum MapTravelMode: String, CaseIterable, Identifiable, Sendable {
    case walking, driving

    var id: String { rawValue }
    var title: String { self == .walking ? "Walking" : "Driving" }
    var costing: String { self == .walking ? "pedestrian" : "auto" }
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
        case .outsideRegion: "Choose two locations inside the installed routing region."
        case .noRoute: "No route was found between these locations in the installed region."
        case .invalidResponse: "The offline routing engine returned an invalid route."
        }
    }
}
