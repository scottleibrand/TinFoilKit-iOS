import CoreLocation
import Foundation

enum OfflineReadinessRegionalChecks {
    static func places(query: String) async -> OfflineReadinessCheckResult {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.prefix(256).contains(where: { $0.isLetter || $0.isNumber }) else {
            return .unavailable("Enter a known address, place, or service in an installed region.")
        }

        let lookup = Task.detached(priority: .userInitiated) { () async throws -> OfflineReadinessCheckResult in
            try Task.checkCancellation()
            let indexes = try await RegionalPlaceStorage().installedIndexes()
            try Task.checkCancellation()
            guard !indexes.isEmpty else {
                return .unavailable("Install regional place data from Map to check offline search.")
            }
            let search = RegionalPlaceSearch(regions: indexes)
            guard let match = try search.search(query, near: nil, limit: 1).first else {
                return .failed("No match in the installed place data. Try a known address or place in an installed region.")
            }
            try Task.checkCancellation()
            let place = match.place
            let name: String
            if place.address.isEmpty {
                name = place.name
            } else if place.address == place.name || place.address.hasPrefix(place.name + ",") {
                name = place.address
            } else {
                name = "\(place.name), \(place.address)"
            }
            return .passed("Found \(name) in the \(match.region.metadata.region) place data.")
        }
        do {
            let result = try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() }
            try Task.checkCancellation()
            return result
        } catch is CancellationError {
            return .unavailable("The place check was cancelled.")
        } catch {
            return .failed("The installed place index could not be searched. Check the installed place data in Map.")
        }
    }

    static func route(from origin: MapRoute.Point, to destination: MapRoute.Point,
                      mode: MapTravelMode) async -> OfflineReadinessCheckResult {
        guard CLLocationCoordinate2DIsValid(origin.coordinate), CLLocationCoordinate2DIsValid(destination.coordinate),
              origin.latitude != destination.latitude || origin.longitude != destination.longitude else {
            return .unavailable("Choose two different locations with valid coordinates.")
        }

        do {
            try Task.checkCancellation()
            let route = try await RegionalRouteStore().route(from: origin, to: destination, mode: mode)
            try Task.checkCancellation()
            guard route.meters.isFinite, route.meters > 0, !route.steps.isEmpty else {
                return .failed("The routing pack returned no distance or directions. Try locations farther apart.")
            }
            let distance = Measurement(value: route.meters, unit: UnitLength.meters)
                .formatted(.measurement(width: .abbreviated, usage: .road))
            let steps = route.steps.count
            let stepLabel = steps == 1 ? "step" : "steps"
            return .passed("Calculated a \(mode.rawValue) route of \(distance) with \(steps.formatted()) \(stepLabel).")
        } catch is CancellationError {
            return .unavailable("The route check was cancelled.")
        } catch RouteError.outsideRegion {
            return .unavailable("Choose start and destination points in the same installed routing pack.")
        } catch RouteError.noRoute {
            return .failed("The installed routing pack found no \(mode.rawValue) route between those points.")
        } catch {
            return .failed("The installed routing pack could not calculate the route. Check the routing packs in Map.")
        }
    }
}
