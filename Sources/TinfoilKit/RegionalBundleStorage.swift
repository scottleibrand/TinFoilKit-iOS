import CryptoKit
import Foundation

actor RegionalBundleStorage {
    struct Installed: Identifiable, Sendable {
        let id: UUID
        let manifest: RegionalBundleManifest
    }

    struct Edition: Sendable {
        let folder: URL
        let installed: Installed

        var places: URL { folder.appendingPathComponent("places.sqlite") }
        var routing: URL { folder.appendingPathComponent("routing", isDirectory: true) }
    }

    static let defaultDirectory = URL.applicationSupportDirectory.appendingPathComponent("RegionalBundles", isDirectory: true)
    private static let lock = NSLock()
    private let directory: URL

    init(directory: URL = RegionalBundleStorage.defaultDirectory) {
        self.directory = directory
    }

    func installedBundles() throws -> [Installed] {
        try Self.editions(in: directory).map(\.installed)
    }

    func install(_ source: URL) throws -> Installed {
        guard source.isFileURL else { throw RegionalBundleManifest.Error.invalidManifest }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard accessed else { return try installFolder(source) }
        var coordinationError: NSError?
        var result: Result<Installed, Swift.Error>?
        NSFileCoordinator().coordinate(readingItemAt: source, options: [], error: &coordinationError) { folder in
            result = Result { try installFolder(folder) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw RegionalBundleManifest.Error.invalidManifest }
        return try result.get()
    }

    func remove(_ id: UUID) throws {
        try Self.lock.withLock {
            let folder = directory.appendingPathComponent(id.uuidString, isDirectory: true)
            guard Self.isDirectory(folder) else { return }
            let removed = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("partial")
            let files = FileManager.default
            try files.moveItem(at: folder, to: removed)
            try? files.removeItem(at: removed)
        }
    }

    static func editions(in directory: URL?) throws -> [Edition] {
        let files = FileManager.default
        guard let directory, files.fileExists(atPath: directory.path) else { return [] }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        return try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .compactMap { folder in
                guard let id = UUID(uuidString: folder.lastPathComponent), Self.isDirectory(folder),
                      let manifest = try? RegionalBundleManifest.read(from: folder.appendingPathComponent("manifest.json"))
                else { return nil }
                let edition = Edition(folder: folder, installed: Installed(id: id, manifest: manifest))
                guard Self.isDirectory(edition.routing),
                      (try? Self.regularFileSize(edition.places)) == manifest.assets.places.byteCount,
                      (try? Self.regularFileSize(edition.routing.appendingPathComponent("manifest.json"))) != nil,
                      (try? Self.regularFileSize(edition.routing.appendingPathComponent("tiles.tar"))) != nil else { return nil }
                return edition
            }.sorted { lhs, rhs in
                let order = lhs.installed.manifest.region.localizedStandardCompare(rhs.installed.manifest.region)
                return order == .orderedSame
                    ? lhs.installed.id.uuidString < rhs.installed.id.uuidString : order == .orderedAscending
            }
    }

    private func installFolder(_ source: URL) throws -> Installed {
        try Self.lock.withLock {
            try Task.checkCancellation()
            guard Self.isDirectory(source) else { throw RegionalBundleManifest.Error.invalidManifest }
            let manifest = try RegionalBundleManifest.read(from: source.appendingPathComponent("manifest.json"))
            let files = FileManager.default
            var root = directory
            try files.createDirectory(at: root, withIntermediateDirectories: true)
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try root.setResourceValues(attributes)
            try removeInterruptedImports()
            let assets = manifest.assets
            let (routeSpace, routeOverflow) = assets.routing.byteCount.multipliedReportingOverflow(by: 2)
            let (needed, totalOverflow) = assets.places.byteCount.addingReportingOverflow(routeSpace)
            guard !routeOverflow, !totalOverflow else { throw RegionalBundleManifest.Error.invalidManifest }
            if let available = try root.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
                .volumeAvailableCapacityForImportantUsage, available < needed { throw RouteError.storage }

            let id = UUID()
            let ready = root.appendingPathComponent(id.uuidString, isDirectory: true)
            let staging = ready.appendingPathExtension("partial")
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: staging) }
            let placeFile = try Self.copyVerified(assets.places, from: source, to: staging)
            let placeMetadata = try RegionalPlaceStorage.validateIndex(at: placeFile)
            try manifest.validate(places: placeMetadata)

            let routeFile = try Self.copyVerified(assets.routing, from: source, to: staging)
            let routeFolder = staging.appendingPathComponent("routing", isDirectory: true)
            try RegionalRouteStore.stagePack(routeFile, at: routeFolder) { try manifest.validate(routing: $0) }
            try files.removeItem(at: routeFile)
            try JSONEncoder().encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .atomic)
            try Task.checkCancellation()
            if let existing = try installedBundles().first(where: { $0.manifest == manifest }) { return existing }
            try files.moveItem(at: staging, to: ready)
            return Installed(id: id, manifest: manifest)
        }
    }

    private func removeInterruptedImports() throws {
        for folder in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            guard folder.pathExtension == "partial", UUID(uuidString: folder.deletingPathExtension().lastPathComponent) != nil,
                  Self.isDirectory(folder) else { continue }
            try FileManager.default.removeItem(at: folder)
        }
    }

    private static func copyVerified(_ asset: RegionalBundleManifest.Asset, from source: URL, to folder: URL) throws -> URL {
        let from = source.appendingPathComponent(asset.filename)
        try asset.validateFile(at: from)
        let to = folder.appendingPathComponent(asset.filename)
        guard FileManager.default.createFile(atPath: to.path, contents: nil) else { throw RouteError.storage }
        let input = try FileHandle(forReadingFrom: from)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: to)
        defer { try? output.close() }
        var remaining = asset.byteCount
        var sha256 = SHA256()
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            remaining -= Int64(bytes.count)
            guard remaining >= 0 else { throw RegionalBundleManifest.Error.invalidArtifact(asset.filename) }
            sha256.update(data: bytes)
            try output.write(contentsOf: bytes)
        }
        let digest = sha256.finalize().map { String(format: "%02x", $0) }.joined()
        guard remaining == 0, digest == asset.sha256 else { throw RegionalBundleManifest.Error.invalidArtifact(asset.filename) }
        try output.synchronize()
        return to
    }

    private static func regularFileSize(_ file: URL) throws -> Int64 {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw RegionalBundleManifest.Error.invalidArtifact(file.lastPathComponent)
        }
        return Int64(size)
    }

    private static func isDirectory(_ folder: URL) -> Bool {
        let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }
}
