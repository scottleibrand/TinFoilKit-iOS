import CoreLocation
import Foundation

struct RegionalPlaceSearch: Sendable {
    let regions: [RegionalPlaceStorage.Installed]

    struct Match: Identifiable, Sendable {
        let region: RegionalPlaceStorage.Installed
        let place: RegionalPlaceIndex.Place
        var id: String { "\(region.id):\(place.id)" }
    }

    struct Nearby: Sendable {
        let match: Match
        let distanceMeters: Double
    }

    enum InstalledLookup: Sendable {
        case noPlaceData, noMatch, match(Nearby)
    }

    static func nearestInstalled(_ category: RegionalPlaceIndex.Category, from home: HouseholdPlace,
                                 storage: RegionalPlaceStorage) async throws -> InstalledLookup {
        let regions = try await storage.installedIndexes()
        guard !regions.isEmpty else { return .noPlaceData }
        let lookup = Task.detached {
            try RegionalPlaceSearch(regions: regions).nearest(category, to: home.coordinate, limit: 1).first
        }
        let match = try await withTaskCancellationHandler { try await lookup.value } onCancel: { lookup.cancel() }
        return match.map(InstalledLookup.match) ?? .noMatch
    }

    func search(_ query: String, near origin: CLLocationCoordinate2D?, limit: Int = 40) throws -> [Match] {
        guard limit > 0 else { return [] }
        let ordered = regions.enumerated().sorted { lhs, rhs in
            let a = origin.map { lhs.element.metadata.bounds?.contains($0) == true } ?? false
            let b = origin.map { rhs.element.metadata.bounds?.contains($0) == true } ?? false
            return a == b ? lhs.offset < rhs.offset : a
        }.map(\.element)
        let groups = try collect(ordered) { region in
            try region.index.search(query, limit: limit).map { Match(region: region, place: $0) }
        }
        var seen = Set<PlaceKey>()
        var matches: [Match] = []
        for rank in 0..<(groups.map(\.count).max() ?? 0) {
            for group in groups where group.indices.contains(rank) {
                let match = group[rank]
                if seen.insert(PlaceKey(match.place)).inserted { matches.append(match) }
                if matches.count >= limit { return matches }
            }
        }
        return matches
    }

    func nearest(_ category: RegionalPlaceIndex.Category, to origin: CLLocationCoordinate2D,
                 limit: Int = 10) throws -> [Nearby] {
        guard limit > 0 else { return [] }
        let groups = try collect(regions) { region in
            try region.index.nearest(category, to: origin, limit: limit).map {
                Nearby(match: Match(region: region, place: $0.place), distanceMeters: $0.distanceMeters)
            }
        }
        var seen = Set<PlaceKey>()
        let candidates: [Nearby] = groups.flatMap { $0 }
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.distanceMeters == rhs.distanceMeters { return lhs.match.id < rhs.match.id }
            return lhs.distanceMeters < rhs.distanceMeters
        }
        return Array(ordered.filter { seen.insert(PlaceKey($0.match.place)).inserted }.prefix(limit))
    }

    private func collect<Value>(_ sources: [RegionalPlaceStorage.Installed],
                                query: (RegionalPlaceStorage.Installed) throws -> [Value]) throws -> [[Value]] {
        var groups: [[Value]] = []
        var failure: Error?
        for region in sources {
            try Task.checkCancellation()
            do { groups.append(try query(region)) }
            catch is CancellationError { throw CancellationError() }
            catch { failure = error }
        }
        if groups.isEmpty, let failure { throw failure }
        return groups
    }

    private struct PlaceKey: Hashable {
        let name: String
        let latitude: Double
        let longitude: Double

        init(_ place: RegionalPlaceIndex.Place) {
            name = place.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            latitude = (place.coordinate.latitude * 100_000).rounded()
            longitude = (place.coordinate.longitude * 100_000).rounded()
        }
    }
}
