import CryptoKit
import Foundation

public struct InstalledArchive: Identifiable, Equatable, Sendable, Codable {
    public let id: UUID
    public let title: String
    public let byteCount: Int64
    public let pack: PublishedPack?
}

/// Owns imported archive copies and their manifests.
public actor InstalledLibrary {
    public static let standard = InstalledLibrary(
        directory: URL.applicationSupportDirectory.appendingPathComponent("Library", isDirectory: true)
    )

    private let directory: URL
    private let files = FileManager.default

    public init(directory: URL) {
        self.directory = directory
    }

    public func archives() throws -> [InstalledArchive] {
        try prepareDirectory()
        let entries = try files.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        return try entries.compactMap { folder -> InstalledArchive? in
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                return nil
            }
            let manifest = try Data(contentsOf: folder.appendingPathComponent("manifest.json"))
            let entry = try JSONDecoder().decode(InstalledArchive.self, from: manifest)
            guard entry.id == id else { throw ImportError.invalidManifest }
            return entry
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    @discardableResult
    public func importArchive(from source: URL) throws -> InstalledArchive {
        try installArchive(from: source, pack: nil)
    }

    @discardableResult
    public func installPack(_ pack: PublishedPack, from source: URL) throws -> InstalledArchive {
        if let installed = try archives().first(where: { $0.pack == pack }) { return installed }
        return try installArchive(from: source, pack: pack)
    }

    private func installArchive(from source: URL, pack: PublishedPack?) throws -> InstalledArchive {
        guard source.isFileURL, source.pathExtension.caseInsensitiveCompare("zim") == .orderedSame else {
            throw ImportError.invalidFile
        }
        try prepareDirectory()
        let id = UUID()
        let staging = directory.appendingPathComponent(".\(id.uuidString).partial")
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        let stagedFile = staging.appendingPathComponent("archive.zim")

        let accessed = source.startAccessingSecurityScopedResource()
        defer { if accessed { source.stopAccessingSecurityScopedResource() } }
        if accessed {
            var coordinationError: NSError?
            var copyError: Error?
            NSFileCoordinator().coordinate(
                readingItemAt: source,
                options: .withoutChanges,
                error: &coordinationError
            ) { file in
                do {
                    try copyArchive(file, to: stagedFile)
                } catch {
                    copyError = error
                }
            }
            if let error = coordinationError { throw error }
            if let error = copyError { throw error }
        } else {
            try copyArchive(source, to: stagedFile)
        }

        if let pack { try verify(stagedFile, expectedHash: pack.sha256) }
        let archive = try ZIMArchive(fileURL: stagedFile)
        guard archive.entryCount > 0 else { throw ImportError.emptyArchive }
        let values = try stagedFile.resourceValues(forKeys: [.fileSizeKey])
        let entry = InstalledArchive(
            id: id,
            title: pack?.title ?? archive.title ?? source.deletingPathExtension().lastPathComponent,
            byteCount: Int64(values.fileSize ?? 0),
            pack: pack
        )
        let manifest = try JSONEncoder().encode(entry)
        try manifest.write(to: staging.appendingPathComponent("manifest.json"))
        try files.moveItem(at: staging, to: directory.appendingPathComponent(id.uuidString))
        return entry
    }

    public func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathComponent("archive.zim")
    }

    private func copyArchive(_ file: URL, to destination: URL) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true else {
            throw ImportError.invalidFile
        }
        try files.copyItem(at: file, to: destination)
    }

    private func verify(_ file: URL, expectedHash: String) throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: bytes)
        }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == expectedHash else { throw ImportError.checksumMismatch }
    }

    private func prepareDirectory() throws {
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        var url = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private enum ImportError: LocalizedError {
        case invalidFile
        case emptyArchive
        case invalidManifest
        case checksumMismatch

        var errorDescription: String? {
            switch self {
            case .invalidFile: "Choose a single .zim archive from Files."
            case .emptyArchive: "This archive has no entries."
            case .invalidManifest: "The installed archive manifest is invalid."
            case .checksumMismatch: "The download does not match the publisher’s checksum."
            }
        }
    }
}
