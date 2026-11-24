import CryptoKit
import Foundation

struct RoutingPack: Codable, Equatable, Sendable {
    static let engine = "3.9.2"
    static let engineRevision = "a919bb6b64d61d12f79ea5466d5cf599a39714ad"
    static let timezoneVersion = "2025b"

    struct Bounds: Codable, Equatable, Sendable {
        let west: Double
        let south: Double
        let east: Double
        let north: Double

        var isValid: Bool {
            (-180...180).contains(west) && (-180...180).contains(east) && west != east
            && (-90...90).contains(south) && (-90...90).contains(north) && south < north
        }

        func contains(_ point: MapRoute.Point) -> Bool {
            guard (south...north).contains(point.latitude) else { return false }
            if west < east { return (west...east).contains(point.longitude) }
            return point.longitude >= west || point.longitude <= east
        }
    }

    let schemaVersion: Int
    let region: String
    let dataVersion: String
    let engineVersion: String
    let engineCommit: String
    let timeZoneDataVersion: String
    let bounds: Bounds
    let source: URL
    let sourceSHA256: String
    let attribution: String
    let license: String
    let licenseURL: URL
    let graphByteCount: Int64
    let graphSHA256: String

    func validate() throws {
        guard schemaVersion == 1, engineVersion == Self.engine, engineCommit == Self.engineRevision,
              timeZoneDataVersion == Self.timezoneVersion else { throw RouteError.incompatiblePack }
        guard bounds.isValid, !region.isEmpty, region.count <= 120, !dataVersion.isEmpty,
              source.scheme == "https", source.host != nil, source.user == nil,
              Self.isSHA256(sourceSHA256), Self.isSHA256(graphSHA256),
              graphByteCount > 1_024, graphByteCount.isMultiple(of: 512),
              attribution == "© OpenStreetMap contributors",
              license == "ODbL-1.0", licenseURL.absoluteString == "https://www.openstreetmap.org/copyright" else {
            throw RouteError.invalidPack
        }
    }

    private static func isSHA256(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

actor RegionalRouteStore {
    struct Installed: Equatable, Sendable {
        let id: UUID
        let pack: RoutingPack
    }

    private let directory: URL
    private var engine: RouteEngine?
    private var active: Installed?
    private var selection: URL { directory.appendingPathComponent("current") }

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("RoutingGraphs", isDirectory: true)) {
        self.directory = directory
    }

    func current() throws -> Installed? {
        if let active { return active }
        guard FileManager.default.fileExists(atPath: selection.path) else { return nil }
        guard let id = UUID(uuidString: try String(contentsOf: selection, encoding: .utf8)) else {
            throw RouteError.invalidPack
        }
        let folder = installedFolder(id)
        let bytes = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
        let pack = try JSONDecoder().decode(RoutingPack.self, from: bytes)
        try pack.validate()
        let graph = folder.appendingPathComponent("tiles.tar")
        guard try Int64(graph.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == pack.graphByteCount else {
            throw RouteError.invalidPack
        }
        let installed = Installed(id: id, pack: pack)
        active = installed
        return installed
    }

    func install(_ source: URL) throws -> Installed {
        guard source.isFileURL, source.pathExtension.lowercased() == "tfkroute" else { throw RouteError.invalidPack }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard accessed else { return try importFile(source) }
        var coordinationError: NSError?
        var result: Result<Installed, Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { file in
            result = Result { try importFile(file) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw RouteError.invalidPack }
        return try result.get()
    }

    func route(_ installed: Installed, from origin: MapRoute.Point, to destination: MapRoute.Point,
               mode: MapTravelMode) throws -> MapRoute {
        guard try current() == installed, installed.pack.bounds.contains(origin),
              installed.pack.bounds.contains(destination) else { throw RouteError.outsideRegion }
        try Task.checkCancellation()
        if engine == nil {
            engine = try RouteEngine(folder: installedFolder(installed.id))
        }
        guard let engine else { throw RouteError.engineUnavailable }
        let route = try engine.route(from: origin, to: destination, mode: mode)
        try Task.checkCancellation()
        return route
    }

    private func installedFolder(_ id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func importFile(_ source: URL) throws -> Installed {
        let (pack, manifest, input) = try Self.openPack(source)
        defer { try? input.close() }
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        if let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, available < pack.graphByteCount {
            throw RouteError.storage
        }

        let id = UUID()
        let folder = installedFolder(id)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        var committed = false
        defer { if !committed { try? files.removeItem(at: folder) } }
        try Self.writeGraph(from: input, pack: pack, to: folder.appendingPathComponent("tiles.tar"))
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        let candidate = try RouteEngine(folder: folder)
        let oldID = (try? String(contentsOf: selection, encoding: .utf8)).flatMap(UUID.init(uuidString:))
        try Data(id.uuidString.utf8).write(to: selection, options: .atomic)
        committed = true
        let installed = Installed(id: id, pack: pack)
        engine = candidate
        active = installed
        if let oldID { try? files.removeItem(at: installedFolder(oldID)) }
        return installed
    }

    private static func openPack(_ source: URL) throws -> (RoutingPack, Data, FileHandle) {
        let info = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, let fileSize = info.fileSize else {
            throw RouteError.invalidPack
        }
        let input = try FileHandle(forReadingFrom: source)
        do {
            guard let header = try input.read(upToCount: 12), header.count == 12,
                  header.prefix(8) == Data("TFKROUTE".utf8) else { throw RouteError.invalidPack }
            let length = Int(header.dropFirst(8).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian)
            guard (1...65_536).contains(length), let data = try input.read(upToCount: length), data.count == length,
                  let pack = try? JSONDecoder().decode(RoutingPack.self, from: data),
                  Int64(fileSize - 12 - length) == pack.graphByteCount else { throw RouteError.invalidPack }
            try pack.validate()
            return (pack, data, input)
        } catch {
            try? input.close()
            throw error
        }
    }

    private static func writeGraph(from input: FileHandle, pack: RoutingPack, to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw RouteError.storage }
        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }
        var count = Int64(0)
        var sha256 = SHA256()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            guard count <= pack.graphByteCount else { throw RouteError.invalidPack }
            try output.write(contentsOf: chunk)
            sha256.update(data: chunk)
        }
        let digest = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == pack.graphByteCount, digest == pack.graphSHA256 else { throw RouteError.invalidPack }
        try output.synchronize()
    }
}
