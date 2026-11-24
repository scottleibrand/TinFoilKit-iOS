import CoreLocation
import SQLite3
import SwiftUI

struct MapPlace: Identifiable, Sendable {
    let id: Int64
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
                id: sqlite3_column_int64(statement, 0),
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
    let index: URL
    let onSelect: (MapPlace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var places: [MapPlace] = []
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if failed {
                    ContentUnavailableView("Place search unavailable", systemImage: "magnifyingglass")
                } else if query.isEmpty {
                    ContentUnavailableView("Search for a place", systemImage: "magnifyingglass")
                } else if places.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(places) { place in
                        Button {
                            onSelect(place)
                            dismiss()
                        } label: {
                            VStack(alignment: .leading) {
                                Text(place.name)
                                Text(place.kind.capitalized).font(.caption).foregroundStyle(.secondary)
                            }.foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Places")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Place name or category")
            .toolbar { Button("Done") { dismiss() } }
            .task(id: query) {
                let requested = query
                do {
                    try await Task.sleep(for: .milliseconds(140))
                    let index = self.index
                    let results = try await Task.detached {
                        try MapPlaces(index: index).search(requested)
                    }.value
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
}
