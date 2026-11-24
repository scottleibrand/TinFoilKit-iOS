import Foundation

actor RegionalPlaceStorage {
    struct Installed: Identifiable, Sendable {
        let id: String
        let index: RegionalPlaceIndex
        let metadata: RegionalPlaceIndex.Metadata
        let bundleID: UUID?
    }

    private let directory: URL
    private let bundleDirectory: URL?

    init(directory: URL? = nil, bundleDirectory: URL? = nil) {
        self.directory = directory ?? URL.applicationSupportDirectory.appendingPathComponent("RegionalPlaces", isDirectory: true)
        self.bundleDirectory = bundleDirectory ?? (directory == nil ? RegionalBundleStorage.defaultDirectory : nil)
    }

    private static let legacyID = "current.sqlite"
    private var latestFile: URL { directory.appendingPathComponent("latest-imported") }

    func current() throws -> Installed? {
        let installed = try installedIndexes()
        if let latest = try? String(contentsOf: latestFile, encoding: .utf8),
           let index = installed.first(where: { $0.id == latest }) {
            return index
        }
        return installed.first { $0.id == Self.legacyID } ?? installed.first
    }

    func installedIndexes() throws -> [Installed] {
        let files = FileManager.default
        var indexes: [Installed] = []
        if files.fileExists(atPath: directory.path) {
            try? excludeFromBackup()
            let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
            for file in try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) {
                let id = file.lastPathComponent
                guard Self.isIndexID(id),
                      let values = try? file.resourceValues(forKeys: keys),
                      values.isRegularFile == true, values.isSymbolicLink != true else { continue }
                let index = RegionalPlaceIndex(file: file)
                guard let metadata = try? index.metadata() else { continue }
                indexes.append(Installed(id: id, index: index, metadata: metadata, bundleID: nil))
            }
        }
        for edition in try RegionalBundleStorage.editions(in: bundleDirectory) {
            let index = RegionalPlaceIndex(file: edition.places)
            let bundle = edition.installed
            guard let metadata = try? index.metadata(), (try? bundle.manifest.validate(places: metadata)) != nil else { continue }
            indexes.append(Installed(id: "bundle-\(bundle.id)", index: index, metadata: metadata, bundleID: bundle.id))
        }
        return indexes.sorted { lhs, rhs in
            let comparison = lhs.metadata.region.localizedStandardCompare(rhs.metadata.region)
            return comparison == .orderedSame ? lhs.id < rhs.id : comparison == .orderedAscending
        }
    }

    func remove(_ id: Installed.ID) throws {
        guard Self.isIndexID(id) else { return }
        let file = directory.appendingPathComponent(id)
        if FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    func install(_ source: URL) throws -> Installed {
        guard source.isFileURL, ["sqlite", "sqlite3"].contains(source.pathExtension.lowercased()) else {
            throw RegionalPlaceIndex.IndexError.unsupportedVersion
        }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        try excludeFromBackup()
        let staging = StagingCleanup.beginImport(in: directory, includingLegacyUUIDFiles: true)
        defer { StagingCleanup.endImport(at: staging) }
        func copy(_ file: URL) throws {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw RegionalPlaceIndex.IndexError.unreadable
            }
            try files.copyItem(at: file, to: staging)
        }
        if accessed {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) {
                do { try copy($0) }
                catch { copyError = error }
            }
            if let coordinationError { throw coordinationError }
            if let copyError { throw copyError }
        } else {
            try copy(source)
        }

        let metadata = try Self.validateIndex(at: staging)
        try Task.checkCancellation()
        let id = "\(UUID().uuidString).sqlite"
        let file = directory.appendingPathComponent(id)
        try files.moveItem(at: staging, to: file)
        do {
            try Data(id.utf8).write(to: latestFile, options: .atomic)
        } catch {
            try? files.removeItem(at: file)
            throw error
        }
        return Installed(id: id, index: RegionalPlaceIndex(file: file), metadata: metadata, bundleID: nil)
    }

    static func validateIndex(at file: URL) throws -> RegionalPlaceIndex.Metadata {
        let candidate = RegionalPlaceIndex(file: file)
        let metadata = try candidate.metadata()
        _ = try candidate.search("TinfoilKitIndexCheck", limit: 1)
        _ = try candidate.nearest(.hospital, to: .init(latitude: 0, longitude: 0), radiusMeters: 1, limit: 1)
        return metadata
    }

    private func excludeFromBackup() throws {
        var folder = directory
        var values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        guard values.isExcludedFromBackup != true else { return }
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    private static func isIndexID(_ id: String) -> Bool {
        id == legacyID || (id.hasSuffix(".sqlite") && UUID(uuidString: String(id.dropLast(7))) != nil)
    }
}
