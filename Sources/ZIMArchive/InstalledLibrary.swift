import CryptoKit
import Darwin
import Foundation

public struct InstalledArchive: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let title: String
    public let byteCount: Int64
    public let pack: PublishedPack?
    public let replacesArchiveID: UUID?

    public init(
        id: UUID, title: String, byteCount: Int64, pack: PublishedPack?,
        replacesArchiveID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.byteCount = byteCount
        self.pack = pack
        self.replacesArchiveID = replacesArchiveID
    }
}

/// Owns imported archive copies and their manifests.
public actor InstalledLibrary {
    public struct PublisherChecksumMismatch: LocalizedError {
        public var errorDescription: String? { "The download does not match the publisher’s checksum." }
    }

    /// The installed archives, plus folders whose manifest or archive can no longer be read.
    public struct Inventory: Equatable, Sendable {
        public let archives: [InstalledArchive]
        public let damaged: [UUID]
    }

    public static let standard = InstalledLibrary(
        directory: URL.applicationSupportDirectory.appendingPathComponent("Library", isDirectory: true)
    )

    private let directory: URL
    private let files = FileManager.default
    private var activeStaging: Set<UUID> = []
    private var activeEditions: Set<String> = []
    private var activePublishedImports: Set<String> = []
    private var busyArchives: Set<UUID> = []

    public init(directory: URL) {
        self.directory = directory
    }

    public func archives() throws -> [InstalledArchive] {
        try inventory().archives
    }

    public func inventory() throws -> Inventory {
        try prepareDirectory()
        let entries = try files.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        var archives: [InstalledArchive] = []
        var damaged: [UUID] = []
        for folder in entries {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            // One unreadable folder must not hide the rest of the library.
            if let entry = try? JSONDecoder().decode(
                InstalledArchive.self, from: Data(contentsOf: folder.appendingPathComponent("manifest.json"))
            ), entry.id == id, files.fileExists(atPath: fileURL(for: id).path) {
                archives.append(entry)
            } else {
                damaged.append(id)
            }
        }
        return Inventory(
            archives: archives.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending },
            damaged: damaged.sorted { $0.uuidString < $1.uuidString }
        )
    }

    /// Copies an archive into the library. Cancel the calling task to stop the copy.
    @discardableResult
    public func importArchive(
        from source: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> InstalledArchive {
        try await installArchive(from: source, pack: nil, moving: false, progress: progress)
    }

    /// Imports a publisher-approved local file with an exact byte count and SHA-256.
    @discardableResult
    public func importPublishedPack(
        _ pack: PublishedPack, from source: URL,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> InstalledArchive {
        try await installVerifiedPublisherFile(pack, from: source, moving: false, progress: progress)
    }

    @discardableResult
    public func installDownloadedPublishedPack(_ pack: PublishedPack, from source: URL) async throws -> InstalledArchive {
        try await installVerifiedPublisherFile(pack, from: source, moving: true, progress: { _ in })
    }

    private func installVerifiedPublisherFile(
        _ pack: PublishedPack, from source: URL, moving: Bool, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledArchive {
        guard pack.sizeEstimate > 0 else { throw ImportError.sizeMismatch }
        guard activeEditions.insert(pack.editionKey).inserted else { throw ImportError.busy }
        defer { activeEditions.remove(pack.editionKey) }
        guard activePublishedImports.insert(pack.sha256).inserted else { throw ImportError.busy }
        defer { activePublishedImports.remove(pack.sha256) }
        return try await installArchive(from: source, pack: pack, moving: moving,
                                        expectedByteCount: pack.sizeEstimate, progress: progress)
    }

    @discardableResult
    public func installPack(
        _ pack: PublishedPack, from source: URL, replacing previousID: UUID? = nil, movingSource: Bool = false,
        expectedByteCount: Int64? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> InstalledArchive {
        guard activeEditions.insert(pack.editionKey).inserted else { throw ImportError.busy }
        defer { activeEditions.remove(pack.editionKey) }
        if let previousID, !busyArchives.insert(previousID).inserted { throw ImportError.busy }
        defer { if let previousID { busyArchives.remove(previousID) } }
        let installed = try archives()
        if let previousID {
            guard let entry = installed.first(where: { $0.id == previousID }),
                  let previous = entry.pack,
                  !installed.contains(where: { $0.id == entry.replacesArchiveID }),
                  previous.id == pack.id, previous.version < pack.version else {
                throw ImportError.invalidUpdate
            }
            if let pending = installed.first(where: { $0.replacesArchiveID == previousID }) {
                guard pending.pack == pack else { throw ImportError.invalidUpdate }
                return pending
            }
        }
        if let existing = installed.first(where: { $0.pack == pack }) {
            guard let previousID else { return existing }
            guard !installed.contains(where: { $0.id == existing.replacesArchiveID }) else {
                throw ImportError.invalidUpdate
            }
            // Reuse a verified edition installed separately if the user now wants it to replace the old one.
            guard busyArchives.insert(existing.id).inserted else { throw ImportError.busy }
            defer { busyArchives.remove(existing.id) }
            try await verifyArchive(existing, expectedByteCount: expectedByteCount)
            try Task.checkCancellation()
            let replacement = InstalledArchive(
                id: existing.id, title: existing.title, byteCount: existing.byteCount,
                pack: pack, replacesArchiveID: previousID
            )
            try JSONEncoder().encode(replacement).write(to: manifestURL(for: existing.id), options: .atomic)
            return replacement
        }
        return try await installArchive(
            from: source, pack: pack, replacesArchiveID: previousID, moving: movingSource,
            expectedByteCount: expectedByteCount, progress: progress
        )
    }

    /// An update survives restart as two installed archives until the replacement's index is ready.
    func finishUpdate(_ replacement: InstalledArchive) throws -> UUID? {
        guard let previousID = replacement.replacesArchiveID,
              let pack = replacement.pack,
              ArticleIndex(archiveURL: fileURL(for: replacement.id)).isReady else { return nil }
        let installed = try archives()
        guard installed.contains(replacement),
              let previous = installed.first(where: { $0.id == previousID })?.pack,
              previous.id == pack.id, previous.version < pack.version else { return nil }
        try removeArchive(previousID)
        return previousID
    }

    /// Verify the replacement's bytes before replacing the installed archive of the same edition.
    public func repairPack(
        _ pack: PublishedPack, archiveID: UUID, from source: URL, movingSource: Bool = false,
        expectedByteCount: Int64? = nil
    ) async throws {
        guard source.isFileURL, source.pathExtension.lowercased() == "zim",
              try archives().contains(where: { $0.id == archiveID && $0.pack == pack }) else {
            throw ImportError.invalidRepair
        }
        guard busyArchives.insert(archiveID).inserted else { throw ImportError.busy }
        defer { busyArchives.remove(archiveID) }

        try await withStagedArchive(
            id: UUID(), source: source, pack: pack, moving: movingSource, expectedByteCount: expectedByteCount
        ) { staged, _ in
            let original = fileURL(for: archiveID)
            try staged.withUnsafeFileSystemRepresentation { source in
                try original.withUnsafeFileSystemRepresentation { destination in
                    guard let source, let destination, rename(source, destination) == 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                }
            }
        }
    }

    private func installArchive(
        from source: URL, pack: PublishedPack?, replacesArchiveID: UUID? = nil,
        moving: Bool, expectedByteCount: Int64? = nil, progress: @escaping @Sendable (Double) -> Void
    ) async throws -> InstalledArchive {
        let id = UUID()
        return try await withStagedArchive(id: id, source: source, pack: pack, moving: moving,
                                           expectedByteCount: expectedByteCount, progress: progress) {
            stagedFile, archiveTitle in
            if replacesArchiveID == nil, let pack, let expectedByteCount {
                if let existing = try await verifiedEdition(matching: pack, byteCount: expectedByteCount) {
                    return existing
                }
                try Task.checkCancellation()
            }
            let values = try stagedFile.resourceValues(forKeys: [.fileSizeKey])
            let entry = InstalledArchive(
                id: id,
                title: pack?.title ?? archiveTitle ?? source.deletingPathExtension().lastPathComponent,
                byteCount: Int64(values.fileSize ?? 0),
                pack: pack,
                replacesArchiveID: replacesArchiveID
            )
            let staging = stagedFile.deletingLastPathComponent()
            let manifest = try JSONEncoder().encode(entry)
            try manifest.write(to: staging.appendingPathComponent("manifest.json"))
            try files.moveItem(at: staging, to: directory.appendingPathComponent(id.uuidString))
            return entry
        }
    }

    private func verifiedEdition(matching pack: PublishedPack, byteCount: Int64) async throws -> InstalledArchive? {
        let candidates = try archives().filter { $0.pack?.sha256 == pack.sha256 && $0.byteCount == byteCount }
        for candidate in candidates {
            guard busyArchives.insert(candidate.id).inserted else { throw ImportError.busy }
            defer { busyArchives.remove(candidate.id) }
            do {
                try await verifyArchive(candidate, expectedByteCount: byteCount)
                try Task.checkCancellation()
                return candidate
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A damaged edition cannot stand in for the newly verified copy.
                try Task.checkCancellation()
            }
        }
        return nil
    }

    private func withStagedArchive<Result>(
        id: UUID, source: URL, pack: PublishedPack?, moving: Bool, expectedByteCount: Int64? = nil,
        progress: @escaping @Sendable (Double) -> Void = { _ in },
        publish: (URL, String?) async throws -> Result
    ) async throws -> Result {
        guard source.isFileURL, source.pathExtension.lowercased() == "zim" else {
            throw ImportError.invalidFile
        }
        try prepareDirectory()
        let staging = directory.appendingPathComponent(".\(id.uuidString).partial")
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        activeStaging.insert(id)
        defer {
            activeStaging.remove(id)
            try? files.removeItem(at: staging)
        }
        let stagedFile = staging.appendingPathComponent("archive.zim")
        let storage = directory
        let work = Task.detached(priority: .userInitiated) { () throws -> String? in
            try Task.checkCancellation()
            let candidate: URL
            if moving {
                _ = try Self.regularFileSize(source)
                candidate = source
            } else {
                try Self.stageCopy(source, to: stagedFile, storage: storage,
                                   expectedByteCount: expectedByteCount, progress: progress)
                candidate = stagedFile
            }
            if let pack { try Self.verify(candidate, expectedHash: pack.sha256, expectedByteCount: expectedByteCount) }
            try Task.checkCancellation()
            let archive = try ZIMArchive(fileURL: candidate)
            guard archive.entryCount > 0 else { throw ImportError.emptyArchive }
            return archive.title
        }
        let archiveTitle = try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
        try Task.checkCancellation()
        if moving { try files.moveItem(at: source, to: stagedFile) }
        return try await publish(stagedFile, archiveTitle)
    }

    public func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathComponent("archive.zim")
    }

    private func manifestURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathComponent("manifest.json")
    }

    public func removeArchive(_ id: UUID) throws {
        guard !busyArchives.contains(id) else { throw ImportError.busy }
        let folder = directory.appendingPathComponent(id.uuidString)
        guard files.fileExists(atPath: folder.path) else { return }
        let removed = directory.appendingPathComponent(".\(id.uuidString).removed")
        try files.moveItem(at: folder, to: removed)
        try? files.removeItem(at: removed)
    }

    public func verifyArchive(_ entry: InstalledArchive) async throws {
        try await verifyArchive(entry, expectedByteCount: nil)
    }

    private func verifyArchive(_ entry: InstalledArchive, expectedByteCount: Int64?) async throws {
        let file = fileURL(for: entry.id)
        let verification = Task.detached(priority: .utility) {
            if let pack = entry.pack {
                try Self.verify(file, expectedHash: pack.sha256, expectedByteCount: expectedByteCount)
            }
            let archive = try ZIMArchive(fileURL: file)
            guard archive.entryCount > 0 else { throw ImportError.emptyArchive }
            if entry.pack == nil { try archive.verifyEmbeddedChecksum() }
        }
        try await withTaskCancellationHandler {
            try await verification.value
        } onCancel: {
            verification.cancel()
        }
    }

    /// Bytes an archive of this size needs: its copy plus room for a search index of similar size.
    public static func requiredBytes(forArchiveOf size: Int64) -> Int64 {
        let margin: Int64 = 64 * 1024 * 1024
        return min(max(0, size), (Int64.max - margin) / 2) * 2 + margin
    }

    private static func stageCopy(
        _ source: URL, to destination: URL, storage: URL, expectedByteCount: Int64?,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        guard accessed else {
            try copy(source, to: destination, storage: storage,
                     expectedByteCount: expectedByteCount, progress: progress)
            return
        }
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordinationError) { file in
            do {
                try copy(file, to: destination, storage: storage,
                         expectedByteCount: expectedByteCount, progress: progress)
            } catch {
                copyError = error
            }
        }
        if let error = coordinationError { throw error }
        if let error = copyError { throw error }
    }

    private static func regularFileSize(_ file: URL) throws -> Int64 {
        // A download can replace or truncate the file while reusing the original URL.
        let current = URL(fileURLWithPath: file.path)
        let values = try current.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize else {
            throw ImportError.invalidFile
        }
        return Int64(size)
    }

    private static func copy(
        _ file: URL, to destination: URL, storage: URL, expectedByteCount: Int64?,
        progress: @escaping @Sendable (Double) -> Void
    ) throws {
        let size = try regularFileSize(file)
        if let expectedByteCount, size != expectedByteCount { throw ImportError.sizeMismatch }
        let available = try storage.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        let required = requiredBytes(forArchiveOf: size)
        if let available, available < required {
            throw InsufficientStorage(shortfall: required - available)
        }

        guard FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copied: Int64 = 0
        var reported = -1.0
        progress(0)
        while let chunk = try input.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty {
            try Task.checkCancellation()
            if let expectedByteCount, Int64(chunk.count) > expectedByteCount - copied {
                throw ImportError.sizeMismatch
            }
            try output.write(contentsOf: chunk)
            copied += Int64(chunk.count)
            let fraction = size > 0 ? min(1, Double(copied) / Double(size)) : 1
            if fraction - reported >= 0.01 {
                reported = fraction
                progress(fraction)
            }
        }
        if let expectedByteCount, copied != expectedByteCount { throw ImportError.sizeMismatch }
        progress(1)
    }

    private static func verify(_ file: URL, expectedHash: String, expectedByteCount: Int64?) throws {
        if let expectedByteCount, try regularFileSize(file) != expectedByteCount {
            throw ImportError.sizeMismatch
        }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: bytes)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash else { throw PublisherChecksumMismatch() }
    }

    private func prepareDirectory() throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        let entries = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        for entry in entries where entry.pathExtension == "removed" || entry.pathExtension == "partial" {
            let stem = entry.deletingPathExtension().lastPathComponent
            guard stem.hasPrefix("."), let id = UUID(uuidString: String(stem.dropFirst())),
                  !activeStaging.contains(id) else { continue }
            try? files.removeItem(at: entry)
        }
    }

    private struct InsufficientStorage: LocalizedError {
        let shortfall: Int64

        var errorDescription: String? {
            "Free up at least \(shortfall.formatted(.byteCount(style: .file))) to import and index this archive."
        }
    }

    private enum ImportError: LocalizedError {
        case invalidFile
        case emptyArchive
        case busy
        case sizeMismatch
        case invalidRepair
        case invalidUpdate

        var errorDescription: String? {
            switch self {
            case .invalidFile: "Choose a single .zim archive from Files."
            case .emptyArchive: "This archive has no entries."
            case .busy: "An archive operation is already in progress. Try again when it finishes."
            case .sizeMismatch: "The archive size does not match the publisher’s exact byte count."
            case .invalidRepair: "This edition is no longer installed. Download it from Content packs."
            case .invalidUpdate: "This archive can no longer be updated to the selected edition."
            }
        }
    }
}
