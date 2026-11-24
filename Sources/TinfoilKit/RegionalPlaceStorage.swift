import Darwin
import Foundation

actor RegionalPlaceStorage {
    struct Installed: Sendable {
        let index: RegionalPlaceIndex
        let metadata: RegionalPlaceIndex.Metadata
    }

    private let directory: URL

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("RegionalPlaces", isDirectory: true)) {
        self.directory = directory
    }

    private var file: URL { directory.appendingPathComponent("current.sqlite") }

    func current() throws -> Installed? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let index = RegionalPlaceIndex(file: file)
        return Installed(index: index, metadata: try index.metadata())
    }

    func install(_ source: URL) throws -> Installed {
        guard source.isFileURL, ["sqlite", "sqlite3"].contains(source.pathExtension.lowercased()) else {
            throw RegionalPlaceIndex.IndexError.unsupportedVersion
        }
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }

        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = StagingCleanup.beginImport(in: directory, includingLegacyUUIDFiles: true)
        defer { StagingCleanup.endImport(at: staging) }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) {
            do { try files.copyItem(at: $0, to: staging) }
            catch { copyError = error }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }

        let candidate = RegionalPlaceIndex(file: staging)
        let metadata = try candidate.metadata()
        _ = try candidate.search("TinfoilKitIndexCheck", limit: 1)
        _ = try candidate.nearest(.hospital, to: .init(latitude: 0, longitude: 0), radiusMeters: 1, limit: 1)
        try staging.withUnsafeFileSystemRepresentation { original in
            try file.withUnsafeFileSystemRepresentation { destination in
                guard let original, let destination, rename(original, destination) == 0 else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
        return Installed(index: RegionalPlaceIndex(file: file), metadata: metadata)
    }
}
