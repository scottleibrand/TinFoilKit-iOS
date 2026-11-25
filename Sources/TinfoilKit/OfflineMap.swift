import CoreLocation
import Foundation

struct OfflineMap: Equatable, Identifiable, Sendable {
    let archive: URL
    let title: String
    let minLongitude: Double
    let minLatitude: Double
    let maxLongitude: Double
    let maxLatitude: Double
    let maxZoom: UInt8
    var id: String { regionalBundleID.map(Self.regionalID) ?? archive.lastPathComponent }
    let isBundled: Bool
    let regionalBundleID: UUID?
    let attribution: String?
    let licenseURL: URL?

    var canRemove: Bool { !isBundled && regionalBundleID == nil }
    var bounds: RoutingPack.Bounds {
        .init(west: minLongitude, south: minLatitude, east: maxLongitude, north: maxLatitude)
    }

    static func regionalID(_ bundleID: UUID) -> String { "regional-\(bundleID.uuidString)" }

    var center: CLLocationCoordinate2D {
        CLLocationCoordinate2D(
            latitude: (minLatitude + maxLatitude) / 2,
            longitude: (minLongitude + maxLongitude) / 2
        )
    }

    init(archive: URL, title: String, isBundled: Bool = false, regionalBundleID: UUID? = nil,
         attribution: String? = nil, licenseURL: URL? = nil) throws {
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
        if regionalBundleID != nil {
            try Self.validateLayout(header, fileSize: file.seekToEnd())
        }
        self.archive = archive
        self.title = title
        self.isBundled = isBundled
        self.regionalBundleID = regionalBundleID
        self.attribution = attribution
        self.licenseURL = licenseURL
    }

    private static func validateLayout(_ header: Data, fileSize: UInt64) throws {
        guard header[97...98].allSatisfy({ $0 == 1 || $0 == 2 }) else {
            throw MapError.invalidArchive
        }
        func integer(_ offset: Int) -> UInt64 {
            header.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
        }
        let rootOffset = integer(8)
        let rootLength = integer(16)
        guard rootOffset < 16_384, rootLength > 0, rootLength <= 16_384 - rootOffset, integer(64) > 0 else {
            throw MapError.invalidArchive
        }
        // The header lists root, metadata, leaf and tile sections as offset/length pairs.
        let sections = [8, 24, 40, 56].map { (offset: integer($0), length: integer($0 + 8)) }
        var previousEnd: UInt64 = 127
        for section in sections.filter({ $0.length > 0 }).sorted(by: { $0.offset < $1.offset }) {
            guard section.offset >= previousEnd, section.offset <= fileSize,
                  section.length <= fileSize - section.offset else { throw MapError.invalidArchive }
            previousEnd = section.offset + section.length
        }
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        (minLatitude...maxLatitude).contains(coordinate.latitude)
            && (minLongitude...maxLongitude).contains(coordinate.longitude)
    }

    enum MapError: LocalizedError {
        case invalidArchive

        var errorDescription: String? {
            "Choose a PMTiles v3 vector map that uses Mapbox Vector Tiles."
        }
    }
}

struct OfflineMapStyle: Identifiable {
    let id = UUID()
    let seed: OfflineMap?
    let downloadedTiles: URL

    func json(tileRevision: Int) throws -> String {
        let attributes = "© OpenStreetMap contributors · Protomaps"
        let tileTemplate = downloadedTiles.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            + "/{z}/{x}/{y}.pbf"
        // Give MapLibre a new tile pyramid so an earlier file miss is requested again.
        let downloadedSource = "downloaded-\(tileRevision)"
        var sources: [String: Any] = [
            downloadedSource: ["type": "vector", "tiles": [tileTemplate], "maxzoom": 15, "attribution": attributes]
        ]
        if let seed {
            let attribution = seed.attribution?.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") ?? attributes
            sources["installed"] = ["type": "vector", "url": "pmtiles://" + seed.archive.absoluteString,
                                    "attribution": attribution]
        }
        var style: [String: Any] = [
            "version": 8,
            "sources": sources,
            "layers": [
                ["id": "background", "type": "background", "paint": ["background-color": "#f2eee6"]],
                layer("landcover", type: "fill", paint: ["fill-color": "#d8e2cf", "fill-opacity": 0.6]),
                layer("landuse", type: "fill", paint: ["fill-color": "#e3e8d8", "fill-opacity": 0.55]),
                layer("water", type: "fill", geometry: "Polygon", paint: ["fill-color": "#add3de"]),
                layer("waterways", type: "line", sourceLayer: "water", geometry: "LineString", paint: [
                    "line-color": "#add3de",
                    "line-width": ["interpolate", ["linear"], ["zoom"], 7, 0.4, 13, 1.2, 17, 2.6]
                ]),
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
            let language = Locale.current.language.languageCode?.identifier ?? "en"
            let name: [Any] = ["coalesce", ["get", "name:" + language], ["get", "name"], ["get", "name:en"]]
            layers.append(label("places", sourceLayer: "places", text: name, size: 12))
            layers.append(label("street-names", sourceLayer: "roads", text: name, size: 11,
                                minimumZoom: 13, placement: "line"))
            layers.append(label("service-names", sourceLayer: "pois", text: name, size: 11, minimumZoom: 15,
                                filter: ["in", ["get", "kind"], ["literal", ["hospital", "pharmacy", "clinic",
                                         "fire_station", "police", "fuel", "grocery", "supermarket"]]]))
            layers.append(label("address-numbers", sourceLayer: "buildings", text: ["get", "addr_housenumber"],
                                size: 10, minimumZoom: 17, filter: ["==", ["get", "kind"], "address"]))
            style["layers"] = layers
        }
        let layers = style["layers"] as? [[String: Any]] ?? []
        let drawable = Array(layers.dropFirst())
        let sourceIDs = seed == nil ? ["downloaded"] : ["downloaded", "installed"]
        style["layers"] = Array(layers.prefix(1)) + drawable.flatMap { layer in
            sourceIDs.map { source in
                var copy = layer
                copy["id"] = "\(source)-\(layer["id"] as? String ?? "")"
                copy["source"] = source == "downloaded" ? downloadedSource : source
                return copy
            }
        }

        return String(decoding: try JSONSerialization.data(withJSONObject: style), as: UTF8.self)
    }

    private func label(_ id: String, sourceLayer: String, text: [Any], size: Int, minimumZoom: Int = 0,
                       placement: String = "point", filter: [Any]? = nil) -> [String: Any] {
        var layer: [String: Any] = [
            "id": id, "type": "symbol", "source-layer": sourceLayer, "minzoom": minimumZoom,
            "layout": ["text-field": text, "text-font": ["Noto Sans Regular"], "text-size": size,
                       "symbol-placement": placement],
            "paint": ["text-color": "#342d26", "text-halo-color": "#f2eee6", "text-halo-width": 1]
        ]
        if let filter { layer["filter"] = filter }
        return layer
    }

    private func layer(_ name: String, type: String, sourceLayer: String? = nil, geometry: String? = nil,
                       paint: [String: Any]) -> [String: Any] {
        var layer: [String: Any] = ["id": name, "type": type, "source-layer": sourceLayer ?? name, "paint": paint]
        if let geometry {
            layer["filter"] = ["==", ["geometry-type"], geometry]
        }
        return layer
    }
}

actor MapStorage {
    private static let defaultDirectory = URL.applicationSupportDirectory.appendingPathComponent("Maps", isDirectory: true)
    private let directory: URL
    private let bundledMap: URL?
    private let bundleDirectory: URL?
    private var legacyArchive: URL { directory.appendingPathComponent("imported.pmtiles") }
    private var selection: URL { directory.appendingPathComponent("current-basemap") }

    init(
        directory: URL? = nil,
        bundledMap: URL? = Bundle.main.url(forResource: "seattle", withExtension: "pmtiles", subdirectory: "map-assets"),
        bundleDirectory: URL? = nil
    ) {
        self.directory = directory ?? Self.defaultDirectory
        self.bundledMap = bundledMap
        self.bundleDirectory = bundleDirectory ?? (directory == nil ? RegionalBundleStorage.defaultDirectory : nil)
    }

    func current() throws -> OfflineMap? {
        let maps = try installedMaps()
        if let selected = try? String(contentsOf: selection, encoding: .utf8),
           let map = maps.first(where: { $0.id == selected }) {
            return map
        }
        return maps.first { $0.id == legacyArchive.lastPathComponent }
            ?? maps.first(where: \.isBundled) ?? maps.first
    }

    func installedMaps() throws -> [OfflineMap] {
        var maps: [OfflineMap] = []
        if let bundledMap, let map = try? OfflineMap(archive: bundledMap, title: "Seattle area", isBundled: true) {
            maps.append(map)
        }
        if FileManager.default.fileExists(atPath: directory.path) {
            if let legacy = try? OfflineMap(archive: legacyArchive, title: "Imported map") { maps.append(legacy) }
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            let imports = files.compactMap { archive -> OfflineMap? in
                let stem = archive.deletingPathExtension().lastPathComponent
                guard archive.pathExtension == "pmtiles", stem.count > 37,
                      UUID(uuidString: String(stem.prefix(36))) != nil, stem.dropFirst(36).first == "-",
                      (try? archive.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return nil }
                return try? OfflineMap(archive: archive, title: String(stem.dropFirst(37)))
            }
            maps += imports.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return maps + (try RegionalBundleStorage.editions(in: bundleDirectory).compactMap(\.basemap))
    }

    func selectMap(_ id: OfflineMap.ID) throws -> OfflineMap {
        guard let map = try installedMaps().first(where: { $0.id == id }) else {
            throw CocoaError(.fileNoSuchFile)
        }
        try prepareDirectory()
        try Data(map.id.utf8).write(to: selection, options: .atomic)
        return map
    }

    func removeMap(_ id: OfflineMap.ID) throws {
        guard let map = try installedMaps().first(where: { $0.id == id }), map.canRemove else { return }
        try FileManager.default.removeItem(at: map.archive)
    }

    func importMap(from source: URL) throws -> OfflineMap {
        guard source.isFileURL, source.pathExtension.lowercased() == "pmtiles" else {
            throw OfflineMap.MapError.invalidArchive
        }
        let files = FileManager.default
        try prepareDirectory()
        let staging = StagingCleanup.beginImport(in: directory)
        defer { StagingCleanup.endImport(at: staging) }
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
        let sourceName = source.deletingPathExtension().lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = sourceName.isEmpty ? "Imported map" : String(sourceName.unicodeScalars.prefix(48))
        let archive = directory.appendingPathComponent("\(UUID().uuidString)-\(title).pmtiles")
        _ = try OfflineMap(archive: staging, title: title)
        try Task.checkCancellation()
        try files.moveItem(at: staging, to: archive)
        do {
            let map = try OfflineMap(archive: archive, title: title)
            try Data(map.id.utf8).write(to: selection, options: .atomic)
            return map
        } catch {
            try? files.removeItem(at: archive)
            throw error
        }
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var localDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try localDirectory.setResourceValues(values)
    }
}
