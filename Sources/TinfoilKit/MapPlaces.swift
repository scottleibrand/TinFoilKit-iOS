import CoreLocation
import SQLite3
import SwiftUI

struct MapPlace: Identifiable, Sendable {
    let id: String
    let name: String
    let kind: String
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct MapPlaces {
    let index: URL

    func search(_ query: String) throws -> [MapPlace] {
        let words = query.split(whereSeparator: \.isWhitespace).prefix(12)
        guard !words.isEmpty else { return [] }
        let expression = words.map {
            "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"*"
        }.joined(separator: " AND ")

        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        guard sqlite3_open_v2(index.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              let database else { throw CocoaError(.fileReadCorruptFile) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let sql = """
            SELECT rowid, name, kind, latitude, longitude FROM places
            WHERE places MATCH ? ORDER BY bm25(places, 4.0, 1.0) LIMIT 40
            """
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement,
              sqlite3_bind_text(statement, 1, expression, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
                == SQLITE_OK else { throw CocoaError(.fileReadCorruptFile) }
        var results: [MapPlace] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            results.append(MapPlace(
                id: "bundled:\(sqlite3_column_int64(statement, 0))",
                name: String(cString: sqlite3_column_text(statement, 1)),
                kind: String(cString: sqlite3_column_text(statement, 2)),
                latitude: sqlite3_column_double(statement, 3),
                longitude: sqlite3_column_double(statement, 4)
            ))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else { throw CocoaError(.fileReadCorruptFile) }
        return results
    }
}

struct MapPlaceSearch: View {
    let index: URL?
    let regions: [RegionalPlaceStorage.Installed]
    let origin: CLLocationCoordinate2D?
    let savedPlaces: [HouseholdPlace]
    let onSelect: (MapPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var places: [MapPlace] = []
    @State private var failed = false
    @State private var category: RegionalPlaceIndex.Category?

    private var coordinateResult: MapPlace? {
        guard let coordinate = MapCoordinateText.parse(query) else { return nil }
        return MapPlace(id: "coordinates", name: "Coordinates", kind: MapCoordinateText.decimal(coordinate),
                        latitude: coordinate.latitude, longitude: coordinate.longitude)
    }

    private var matchingSavedPlaces: [HouseholdPlace] {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard category == nil else { return [] }
        guard !term.isEmpty else { return savedPlaces }
        return savedPlaces.filter {
            $0.name.localizedStandardContains(term) || $0.note.localizedStandardContains(term)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if coordinateResult != nil || !matchingSavedPlaces.isEmpty || !places.isEmpty {
                    List {
                        if let coordinateResult { result(coordinateResult) }
                        if !matchingSavedPlaces.isEmpty {
                            Section("Saved places") {
                                ForEach(matchingSavedPlaces) { place in
                                    result(MapPlace(
                                        id: "saved:\(place.id)", name: place.name, kind: place.coordinateText,
                                        latitude: place.latitude, longitude: place.longitude
                                    ))
                                }
                            }
                        }
                        ForEach(places) { result($0) }
                    }
                } else if failed {
                    ContentUnavailableView("Place search unavailable", systemImage: "magnifyingglass")
                } else if let category {
                    ContentUnavailableView("No nearby \(category.label.lowercased()) results", systemImage: "location")
                } else if query.isEmpty {
                    ContentUnavailableView("Search for a place", systemImage: "magnifyingglass")
                } else {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Place or coordinates")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                if !regions.isEmpty, origin != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            ForEach(RegionalPlaceIndex.Category.allCases) { item in
                                Button(item.label) {
                                    query = ""
                                    category = item
                                }
                            }
                        } label: {
                            Label("Nearby services", systemImage: "location.magnifyingglass")
                        }
                    }
                }
            }
            .onChange(of: query) {
                if !query.isEmpty { category = nil }
            }
            .task(id: SearchRequest(query: query, category: category)) {
                let requested = query
                let category = self.category
                places = []
                failed = false
                guard (!requested.isEmpty && coordinateResult == nil) || category != nil else { return }
                do {
                    try await Task.sleep(for: .milliseconds(140))
                    let results = try await search(requested, category: category)
                    if !Task.isCancelled {
                        places = results
                        failed = false
                    }
                } catch is CancellationError {
                } catch {
                    if !Task.isCancelled { failed = true }
                }
            }
        }
    }

    private func search(_ query: String, category: RegionalPlaceIndex.Category?) async throws -> [MapPlace] {
        let local = RegionalPlaceSearch(regions: regions)
        let origin = self.origin
        let index = self.index
        let task = Task.detached {
            if let category, let origin {
                return try local.nearest(category, to: origin).map { nearby in
                    let distance = Measurement(value: nearby.distanceMeters, unit: UnitLength.meters)
                        .formatted(.measurement(width: .abbreviated, usage: .road))
                    return Self.mapPlace(nearby.match, detail: distance)
                }
            }
            let matches = try local.search(query, near: origin)
            if !matches.isEmpty { return matches.map { Self.mapPlace($0) } }
            if let index { return try MapPlaces(index: index).search(query) }
            return []
        }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private nonisolated static func mapPlace(_ match: RegionalPlaceSearch.Match, detail: String? = nil) -> MapPlace {
        let place = match.place
        let context = place.address.isEmpty ? place.categoryLabel.capitalized : place.address
        return MapPlace(id: match.id, name: place.name,
                        kind: [context, match.region.metadata.region, detail].compactMap { $0 }.joined(separator: " · "),
                        latitude: place.coordinate.latitude, longitude: place.coordinate.longitude)
    }

    private func result(_ place: MapPlace) -> some View {
        Button {
            onSelect(place)
            dismiss()
        } label: {
            VStack(alignment: .leading) {
                Text(place.name)
                Text(place.kind).font(.caption).foregroundStyle(.secondary)
            }.foregroundStyle(.primary)
        }
    }

    private struct SearchRequest: Equatable {
        let query: String
        let category: RegionalPlaceIndex.Category?
    }
}

private extension RegionalPlaceIndex.Category {
    var label: String { rawValue.replacingOccurrences(of: "_", with: " ").capitalized }
}
