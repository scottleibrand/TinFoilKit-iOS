import CoreLocation
import Foundation

struct OfflineMap: Equatable {
    let archive: URL
    let title: String
    let minLongitude: Double
    let minLatitude: Double
    let maxLongitude: Double
    let maxLatitude: Double
    let maxZoom: UInt8

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
    }

    init(archive: URL, title: String) throws {
        let file = try FileHandle(forReadingFrom: archive)
        defer { try? file.close() }
        guard let header = try file.read(upToCount: 127), header.count == 127,
              header.prefix(7) == Data("PMTiles".utf8), header[7] == 3,
              header[99] == 1, header[100] <= header[101], header[101] <= 30 else {
            throw MapError.invalidArchive
        }
        func coordinate(_ offset: Int) -> Double {
            let raw = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: Int32.self) }
            return Double(Int32(littleEndian: raw)) / 10_000_000
        }
        minLongitude = coordinate(102)
        minLatitude = coordinate(106)
        maxLongitude = coordinate(110)
        maxLatitude = coordinate(114)
        maxZoom = header[101]
        guard minLongitude >= -180, maxLongitude <= 180, minLongitude < maxLongitude,
              minLatitude >= -90, maxLatitude <= 90, minLatitude < maxLatitude else {
            throw MapError.invalidArchive
        }
        self.archive = archive
        self.title = title
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (minLatitude...maxLatitude).contains(coordinate.latitude)
            && (minLongitude...maxLongitude).contains(coordinate.longitude)
    }

    func makeStyle() throws -> URL {
        let attributes = "© OpenStreetMap contributors · Protomaps"
        var style: [String: Any] = [
            "version": 8,
            "sources": ["basemap": [
                "type": "vector",
                "url": "pmtiles://" + archive.absoluteString,
                "attribution": attributes
            ]],
            "layers": [
                ["id": "background", "type": "background", "paint": ["background-color": "#f2eee6"]],
                layer("landcover", type: "fill", paint: ["fill-color": "#d8e2cf", "fill-opacity": 0.6]),
                layer("landuse", type: "fill", paint: ["fill-color": "#e3e8d8", "fill-opacity": 0.55]),
                layer("water", type: "fill", paint: ["fill-color": "#add3de"]),
                layer("buildings", type: "fill", paint: ["fill-color": "#d4cbc0"]),
                layer("boundaries", type: "line", paint: ["line-color": "#968e85", "line-width": 0.8]),
                layer("roads", type: "line", paint: [
                    "line-color": "#b49675",
                    "line-width": ["interpolate", ["linear"], ["zoom"], 7, 0.3, 13, 1.4, 17, 3]
                ])
            ] as [[String: Any]]
        ]
        if let fonts = Bundle.main.url(forResource: "glyphs", withExtension: nil, subdirectory: "map-assets") {
            style["glyphs"] = fonts.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                + "/{fontstack}/{range}.pbf"
            var layers = style["layers"] as? [[String: Any]] ?? []
            layers.append([
                "id": "places",
                "type": "symbol",
                "source": "basemap",
                "source-layer": "places",
                "layout": [
                    "text-field": ["coalesce", ["get", "name:en"], ["get", "name"]],
                    "text-font": ["Noto Sans Regular"],
                    "text-size": 12
                ],
                "paint": ["text-color": "#342d26", "text-halo-color": "#f2eee6", "text-halo-width": 1]
            ])
            style["layers"] = layers
        }

        let output = URL.cachesDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try JSONSerialization.data(withJSONObject: style).write(to: output, options: .atomic)
        return output
    }

    private func layer(_ name: String, type: String, paint: [String: Any]) -> [String: Any] {
        ["id": name, "type": type, "source": "basemap", "source-layer": name, "paint": paint]
    }

    enum MapError: LocalizedError {
        case invalidArchive

        var errorDescription: String? {
            "Choose a PMTiles v3 vector map that uses Mapbox Vector Tiles."
        }
    }
}

actor MapStorage {
    private let directory = URL.applicationSupportDirectory.appendingPathComponent("Maps", isDirectory: true)
    private var archive: URL { directory.appendingPathComponent("imported.pmtiles") }

    func current() throws -> OfflineMap? {
        if FileManager.default.fileExists(atPath: archive.path) {
            return try OfflineMap(archive: archive, title: "Imported map")
        }
        guard let local = Bundle.main.url(forResource: "seattle", withExtension: "pmtiles", subdirectory: "map-assets") else {
            return nil
        }
        return try OfflineMap(archive: local, title: "Seattle area")
    }

    func importMap(from source: URL) throws -> OfflineMap {
        guard source.isFileURL, source.pathExtension.lowercased() == "pmtiles" else {
            throw OfflineMap.MapError.invalidArchive
        }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var localDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localDirectory.setResourceValues(values)
        let staging = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("partial")
        defer { try? files.removeItem(at: staging) }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        if accessed {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) {
                do { try files.copyItem(at: $0, to: staging) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
        } else {
            try files.copyItem(at: source, to: staging)
        }
        _ = try OfflineMap(archive: staging, title: "Imported map")
        if files.fileExists(atPath: archive.path) {
            _ = try files.replaceItemAt(archive, withItemAt: staging)
        } else {
            try files.moveItem(at: staging, to: archive)
        }
        return try OfflineMap(archive: archive, title: "Imported map")
    }
}
