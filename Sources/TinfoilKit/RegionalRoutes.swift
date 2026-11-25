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
            guard (south...north).contains(point.latitude), (-180...180).contains(point.longitude) else { return false }
            if west < east { return (west...east).contains(point.longitude) }
            return point.longitude >= west || point.longitude <= east
        }

        var area: Double {
            let longitudeWidth = west < east ? east - west : 360 - west + east
            let radians = Double.pi / 180
            return longitudeWidth * (sin(north * radians) - sin(south * radians))
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
    struct Installed: Identifiable, Equatable, Sendable {
        let id: UUID
        let pack: RoutingPack
        let bundleID: UUID?
    }

    private static let maximumManifestBytes = 65_536
    private static let importLock = NSLock()
    private let directory: URL
    private let bundleDirectory: URL?
    private var loadedEngine: (id: UUID, engine: RouteEngine)?
    private var graphs: URL { directory.appendingPathComponent("Installed", isDirectory: true) }
    private var legacySelection: URL { directory.appendingPathComponent("current") }

    init(directory: URL? = nil, bundleDirectory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("RoutingGraphs", isDirectory: true)
        self.bundleDirectory = bundleDirectory ?? (directory == nil ? RegionalBundleStorage.defaultDirectory : nil)
    }

    func current() throws -> Installed? {
        try installedPacks().max { lhs, rhs in
            let a = installDate(lhs)
            let b = installDate(rhs)
            return a == b ? lhs.id.uuidString < rhs.id.uuidString : a < b
        }
    }

    func installedPacks() throws -> [Installed] {
        var packs: [Installed] = []
        if let legacy = legacyID(), let pack = try? readPack(legacy) { packs.append(pack) }
        let files = FileManager.default
        if files.fileExists(atPath: graphs.path) {
            let folders = try files.contentsOfDirectory(at: graphs, includingPropertiesForKeys: nil)
            for folder in folders {
                try Task.checkCancellation()
                guard let id = UUID(uuidString: folder.lastPathComponent), !packs.contains(where: { $0.id == id }),
                      let pack = try? readPack(id) else { continue }
                packs.append(pack)
            }
        }
        for edition in try RegionalBundleStorage.editions(in: bundleDirectory) {
            let bundle = edition.installed
            guard !packs.contains(where: { $0.id == bundle.id }),
                  let pack = try? readPack(bundle.id, folder: edition.routing, bundleID: bundle.id),
                  (try? bundle.manifest.validate(routing: pack.pack)) != nil else { continue }
            packs.append(pack)
        }
        return packs.sorted { lhs, rhs in
            let order = lhs.pack.region.localizedStandardCompare(rhs.pack.region)
            return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
        }
    }

    func remove(_ id: Installed.ID) throws {
        try Self.importLock.withLock {
            guard try installedPacks().contains(where: { $0.id == id && $0.bundleID == nil }) else { return }
            if loadedEngine?.id == id { loadedEngine = nil }
            try FileManager.default.removeItem(at: installedFolder(id))
        }
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
        guard try installedPacks().contains(installed), covers(installed, origin, destination) else {
            throw RouteError.outsideRegion
        }
        return try calculate(using: installed, from: origin, to: destination, mode: mode)
    }

    func route(from origin: MapRoute.Point, to destination: MapRoute.Point, mode: MapTravelMode) throws -> MapRoute {
        try routeWithSource(from: origin, to: destination, mode: mode).route
    }

    func routeWithSource(from origin: MapRoute.Point, to destination: MapRoute.Point,
                         mode: MapTravelMode) throws -> (route: MapRoute, pack: RoutingPack) {
        try Task.checkCancellation()
        let candidates = try installedPacks().filter { covers($0, origin, destination) }.sorted { lhs, rhs in
            let a = lhs.pack.bounds.area
            let b = rhs.pack.bounds.area
            if a != b { return a < b }
            let aDate = installDate(lhs)
            let bDate = installDate(rhs)
            return aDate == bDate ? lhs.id.uuidString < rhs.id.uuidString : aDate > bDate
        }
        guard !candidates.isEmpty else { throw RouteError.outsideRegion }
        var failure: Error?
        for candidate in candidates {
            do { return (try calculate(using: candidate, from: origin, to: destination, mode: mode), candidate.pack) }
            catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                if case RouteError.noRoute = error { failure = error }
                else if failure == nil { failure = error }
            }
        }
        throw failure ?? RouteError.noRoute
    }

    private func covers(_ installed: Installed, _ origin: MapRoute.Point, _ destination: MapRoute.Point) -> Bool {
        installed.pack.bounds.contains(origin) && installed.pack.bounds.contains(destination)
    }

    private func calculate(using installed: Installed, from origin: MapRoute.Point, to destination: MapRoute.Point,
                           mode: MapTravelMode) throws -> MapRoute {
        try Task.checkCancellation()
        if loadedEngine?.id != installed.id {
            loadedEngine = nil
            loadedEngine = (installed.id, try RouteEngine(folder: routingFolder(installed)))
        }
        guard let engine = loadedEngine?.engine else { throw RouteError.engineUnavailable }
        let route = try engine.route(from: origin, to: destination, mode: mode)
        try Task.checkCancellation()
        return route
    }

    private func installedFolder(_ id: UUID) -> URL {
        if legacyID() == id { return directory.appendingPathComponent(id.uuidString, isDirectory: true) }
        return graphs.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func routingFolder(_ installed: Installed) -> URL {
        if let bundleID = installed.bundleID, let bundleDirectory {
            return bundleDirectory.appendingPathComponent(bundleID.uuidString, isDirectory: true)
                .appendingPathComponent("routing", isDirectory: true)
        }
        return installedFolder(installed.id)
    }

    private func legacyID() -> UUID? {
        guard let handle = try? FileHandle(forReadingFrom: legacySelection) else { return nil }
        defer { try? handle.close() }
        guard let bytes = try? handle.read(upToCount: 37), bytes.count == 36,
              let value = String(data: bytes, encoding: .utf8) else { return nil }
        return UUID(uuidString: value)
    }

    private func installDate(_ installed: Installed) -> Date {
        (try? routingFolder(installed).resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
    }

    private func readPack(_ id: UUID, folder override: URL? = nil, bundleID: UUID? = nil) throws -> Installed {
        let folder = override ?? installedFolder(id)
        let folderValues = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard folderValues.isDirectory == true, folderValues.isSymbolicLink != true else { throw RouteError.invalidPack }
        let manifest = folder.appendingPathComponent("manifest.json")
        let manifestValues = try manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true else {
            throw RouteError.invalidPack
        }
        let handle = try FileHandle(forReadingFrom: manifest)
        defer { try? handle.close() }
        guard let bytes = try handle.read(upToCount: Self.maximumManifestBytes + 1),
              bytes.count <= Self.maximumManifestBytes else { throw RouteError.invalidPack }
        let pack = try JSONDecoder().decode(RoutingPack.self, from: bytes)
        try pack.validate()
        let graph = folder.appendingPathComponent("tiles.tar")
        let graphValues = try graph.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard graphValues.isRegularFile == true, graphValues.isSymbolicLink != true,
              Int64(graphValues.fileSize ?? 0) == pack.graphByteCount else { throw RouteError.invalidPack }
        return Installed(id: id, pack: pack, bundleID: bundleID)
    }

    private func importFile(_ source: URL) throws -> Installed {
        try Self.importLock.withLock { try importLocked(source) }
    }

    private func importLocked(_ source: URL) throws -> Installed {
        try Task.checkCancellation()
        let (pack, manifest, input) = try Self.openPack(source)
        defer { try? input.close() }
        let files = FileManager.default
        try files.createDirectory(at: graphs, withIntermediateDirectories: true)
        try removeInterruptedImports()
        var root = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try root.setResourceValues(values)
        if let existing = try installedPacks().first(where: { $0.bundleID == nil && $0.pack == pack }) {
            try Self.consumeGraph(from: input, pack: pack)
            return existing
        }
        if let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, available < pack.graphByteCount {
            throw RouteError.storage
        }

        let id = UUID()
        let staging = graphs.appendingPathComponent(id.uuidString).appendingPathExtension("partial")
        defer { try? files.removeItem(at: staging) }
        loadedEngine = nil
        try Self.stageGraph(pack, manifest: manifest, input: input, at: staging)
        try Task.checkCancellation()
        try files.moveItem(at: staging, to: installedFolder(id))
        return Installed(id: id, pack: pack, bundleID: nil)
    }

    static func stagePack(_ source: URL, at folder: URL, validate: (RoutingPack) throws -> Void) throws {
        let (pack, manifest, input) = try openPack(source)
        defer { try? input.close() }
        try validate(pack)
        try stageGraph(pack, manifest: manifest, input: input, at: folder)
    }

    private static func stageGraph(_ pack: RoutingPack, manifest: Data, input: FileHandle, at folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try consumeGraph(from: input, pack: pack, writingTo: folder.appendingPathComponent("tiles.tar"))
        try manifest.write(to: folder.appendingPathComponent("manifest.json"), options: .atomic)
        _ = try RouteEngine(folder: folder)
        // The probe writes absolute staging paths. A route opens a fresh config after publication.
        try? FileManager.default.removeItem(at: folder.appendingPathComponent("engine.json"))
    }

    private func removeInterruptedImports() throws {
        let files = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        for folder in try files.contentsOfDirectory(at: graphs, includingPropertiesForKeys: Array(keys)) {
            guard folder.pathExtension == "partial", UUID(uuidString: folder.deletingPathExtension().lastPathComponent) != nil,
                  let values = try? folder.resourceValues(forKeys: keys), values.isDirectory == true,
                  values.isSymbolicLink != true else { continue }
            try? files.removeItem(at: folder)
        }
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
            guard (1...maximumManifestBytes).contains(length), let data = try input.read(upToCount: length), data.count == length,
                  let pack = try? JSONDecoder().decode(RoutingPack.self, from: data),
                  Int64(fileSize - 12 - length) == pack.graphByteCount else { throw RouteError.invalidPack }
            try pack.validate()
            return (pack, data, input)
        } catch {
            try? input.close()
            throw error
        }
    }

    private static func consumeGraph(from input: FileHandle, pack: RoutingPack, writingTo file: URL? = nil) throws {
        let output: FileHandle?
        if let file {
            guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw RouteError.storage }
            output = try FileHandle(forWritingTo: file)
        } else {
            output = nil
        }
        defer { try? output?.close() }
        var count = Int64(0)
        var sha256 = SHA256()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            count += Int64(chunk.count)
            guard count <= pack.graphByteCount else { throw RouteError.invalidPack }
            try output?.write(contentsOf: chunk)
            sha256.update(data: chunk)
        }
        let digest = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        guard count == pack.graphByteCount, digest == pack.graphSHA256 else { throw RouteError.invalidPack }
        try Task.checkCancellation()
        try output?.synchronize()
    }
}
