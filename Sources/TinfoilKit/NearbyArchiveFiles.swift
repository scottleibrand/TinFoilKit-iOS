import CryptoKit
import Foundation

/// Disk staging for a trusted public archive. A single transfer coordinator owns the directory.
actor NearbyArchiveFiles {
    static let chunkBytes = 256 * 1024
    private static let storageMargin: Int64 = 64 * 1024 * 1024
    private static let retention: TimeInterval = 30 * 24 * 60 * 60

    enum TransferError: Error, Equatable {
        case invalidEdition, invalidFile, invalidOffset, insufficientStorage, incomplete, checksumMismatch
    }

    private let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// Releases disk space for retired editions and abandoned transfers when the coordinator starts.
    func prune(keeping allowedDigests: Set<String>, now: Date = .now) throws {
        let directory = URL(fileURLWithPath: directory.path)
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return }
        let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink == false else {
            throw TransferError.invalidFile
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .contentModificationDateKey]
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
        for file in files {
            try Task.checkCancellation()
            let digest = file.deletingPathExtension().lastPathComponent
            guard file.pathExtension == "zim", Self.isDigest(digest),
                  let info = try? file.resourceValues(forKeys: keys),
                  info.isRegularFile == true, info.isSymbolicLink == false else { continue }
            let expired = info.contentModificationDate.map { now.timeIntervalSince($0) >= Self.retention } ?? false
            if !allowedDigests.contains(digest) || expired {
                try manager.removeItem(at: file)
            }
        }
    }

    /// A file's length determines its resume point. Each appended range is synchronized before returning.
    func prepare(digest: String, byteCount: UInt64, availableBytes: Int64? = nil) throws -> UInt64 {
        try Task.checkCancellation()
        let file = try stagingFile(digest: digest, byteCount: byteCount)
        var directory = self.directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let properties = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard properties.isDirectory == true, properties.isSymbolicLink == false else {
            throw TransferError.invalidFile
        }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)

        var offset = try Self.size(of: file) ?? 0
        if offset > byteCount {
            try FileManager.default.removeItem(at: file)
            offset = 0
        }
        let available = try availableBytes ?? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage
        // The file moves into Library. Reserve its remaining bytes plus room for indexing.
        guard let available, available >= Self.storageMargin,
              Int64(byteCount) <= available - Self.storageMargin,
              Int64(byteCount - offset) <= available - Self.storageMargin - Int64(byteCount) else {
            throw TransferError.insufficientStorage
        }
        return offset
    }

    func append(_ data: Data, at offset: UInt64, digest: String, byteCount: UInt64) throws -> UInt64 {
        try Task.checkCancellation()
        let file = try stagingFile(digest: digest, byteCount: byteCount)
        guard !data.isEmpty, data.count <= Self.chunkBytes,
              offset < byteCount, UInt64(data.count) <= byteCount - offset else {
            throw TransferError.invalidOffset
        }
        if let size = try Self.size(of: file) {
            guard size == offset else { throw TransferError.invalidOffset }
        } else {
            guard offset == 0, FileManager.default.createFile(atPath: file.path, contents: nil) else {
                throw TransferError.invalidOffset
            }
        }

        let output = try FileHandle(forWritingTo: file)
        defer { try? output.close() }
        try output.seek(toOffset: offset)
        do {
            try output.write(contentsOf: data)
            try output.synchronize()
        } catch {
            // Preserve the last acknowledged prefix if the current disk write fails.
            try? output.truncate(atOffset: offset)
            try? output.synchronize()
            throw error
        }
        return offset + UInt64(data.count)
    }

    func verifiedFile(digest: String, byteCount: UInt64) throws -> URL {
        try Task.checkCancellation()
        let file = try stagingFile(digest: digest, byteCount: byteCount)
        guard try Self.size(of: file) == byteCount else { throw TransferError.incomplete }
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        var remaining = byteCount
        while remaining > 0 {
            try Task.checkCancellation()
            guard let data = try input.read(upToCount: Int(min(remaining, UInt64(Self.chunkBytes)))),
                  !data.isEmpty else { throw TransferError.incomplete }
            hash.update(data: data)
            remaining -= UInt64(data.count)
        }
        guard try input.read(upToCount: 1)?.isEmpty != false else { throw TransferError.invalidFile }
        let calculated = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard calculated == digest else {
            try discard(digest: digest)
            throw TransferError.checksumMismatch
        }
        return file
    }

    func discard(digest: String) throws {
        let file = try stagingFile(digest: digest, byteCount: 1)
        guard try Self.size(of: file) != nil else { return }
        try FileManager.default.removeItem(at: file)
    }

    private func stagingFile(digest: String, byteCount: UInt64) throws -> URL {
        guard byteCount > 0, byteCount <= UInt64(Int64.max), Self.isDigest(digest) else {
            throw TransferError.invalidEdition
        }
        return directory.appendingPathComponent(digest).appendingPathExtension("zim")
    }

    private static func isDigest(_ digest: String) -> Bool {
        digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    fileprivate static func size(of file: URL) throws -> UInt64? {
        // Foundation can cache resource values on a reused URL while the file is growing.
        let current = URL(fileURLWithPath: file.path)
        do {
            let values = try current.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink == false, let size = values.fileSize,
                  let bytes = UInt64(exactly: size) else { throw TransferError.invalidFile }
            return bytes
        } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }
}

/// Reads a catalog-authorized local archive one bounded chunk at a time.
actor NearbyArchiveReader {
    private let input: FileHandle
    private var remaining: UInt64

    init(file: URL, byteCount: UInt64, offset: UInt64) throws {
        guard offset < byteCount else { throw NearbyArchiveFiles.TransferError.invalidOffset }
        guard try NearbyArchiveFiles.size(of: file) == byteCount else {
            throw NearbyArchiveFiles.TransferError.invalidFile
        }
        let input = try FileHandle(forReadingFrom: file)
        try input.seek(toOffset: offset)
        self.input = input
        remaining = byteCount - offset
    }

    func nextChunk() throws -> Data? {
        try Task.checkCancellation()
        guard remaining > 0 else { return nil }
        let count = Int(min(remaining, UInt64(NearbyArchiveFiles.chunkBytes)))
        guard let data = try input.read(upToCount: count), !data.isEmpty else {
            throw NearbyArchiveFiles.TransferError.incomplete
        }
        remaining -= UInt64(data.count)
        return data
    }
}
