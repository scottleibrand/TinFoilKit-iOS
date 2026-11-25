import Foundation

extension HouseholdShareDirections {
    private static let maximumPins = 3
    private static let maximumSteps = 120

    static func prepare(for snapshot: HouseholdSnapshot, router: RegionalRouteStore = RegionalRouteStore()) async -> [Self] {
        guard let home = snapshot.home, home.isValid else { return [] }
        let origin = MapRoute.Point(latitude: home.latitude, longitude: home.longitude)
        var results: [Self] = []
        for pin in snapshot.pins.prefix(maximumPins) where pin.isValid {
            let destination = MapRoute.Point(latitude: pin.latitude, longitude: pin.longitude)
            guard origin.latitude != destination.latitude || origin.longitude != destination.longitude else { continue }
            for mode in MapTravelMode.allCases {
                guard !Task.isCancelled else { return [] }
                guard let (route, pack) = try? await router.routeWithSource(from: origin, to: destination, mode: mode),
                      (1...maximumSteps).contains(route.steps.count) else { continue }
                results.append(Self(pinID: pin.id, modeTitle: mode.title, region: pack.region, edition: pack.dataVersion,
                                    steps: route.steps.map(\.instruction)))
            }
        }
        return results
    }
}
