import CryptoKit
import Foundation

struct RegionalDownloadState: Sendable {
    struct Job: Codable, Sendable {
        let schemaVersion: Int
        let manifestSHA256: String
        let cellular: Bool
        var started: Bool

        init(source: RegionalBundleDownloadSource, cellular: Bool) {
            schemaVersion = 1
            manifestSHA256 = source.sha256
            self.cellular = cellular
            started = false
        }
    }

    struct Asset: Sendable {
        private struct Checkpoint: Codable {
            let schemaVersion: Int
            let manifestSHA256: String
            let assetSHA256: String
            let byteCount: Int64
            let validator: String
            let prefixSHA256: String
        }

        struct Resume {
            let offset: Int64
            let validator: String
        }

        let file: URL
        let manifestSHA256: String
        let expected: RegionalBundleManifest.Asset

        private var checkpointFile: URL { file.appendingPathExtension("checkpoint") }

        func resume() throws -> Resume? {
            guard let checkpoint = try? RegionalDownloadState.read(Checkpoint.self, from: checkpointFile),
                  checkpoint.schemaVersion == 1, checkpoint.manifestSHA256 == manifestSHA256,
                  checkpoint.assetSHA256 == expected.sha256,
                  checkpoint.byteCount > 0, checkpoint.byteCount < expected.byteCount,
                  RegionalBundleResponse.strongETag(checkpoint.validator) == checkpoint.validator,
                  RegionalBundleManifest.isSHA256(checkpoint.prefixSHA256),
                  let size = RegionalDownloadState.regularSize(file),
                  size >= checkpoint.byteCount, size <= expected.byteCount else { return nil }
            let hash = try RegionalDownloadState.hash(file, byteCount: checkpoint.byteCount)
            guard RegionalDownloadState.hex(hash) == checkpoint.prefixSHA256 else { return nil }

            // A crash can leave uncommitted bytes after the last synchronized checkpoint.
            if size > checkpoint.byteCount {
                let output = try FileHandle(forWritingTo: file)
                defer { try? output.close() }
                try output.truncate(atOffset: UInt64(checkpoint.byteCount))
                try output.synchronize()
            }
            return Resume(offset: checkpoint.byteCount, validator: checkpoint.validator)
        }

        func save(offset: Int64, validator: String, hash: SHA256) throws {
            try RegionalDownloadState.write(Checkpoint(
                schemaVersion: 1, manifestSHA256: manifestSHA256, assetSHA256: expected.sha256,
                byteCount: offset, validator: validator, prefixSHA256: RegionalDownloadState.hex(hash)
            ), to: checkpointFile)
        }

        func forgetCheckpoint() throws { try RegionalDownloadState.remove(checkpointFile) }

        func reset() throws {
            try forgetCheckpoint()
            try RegionalDownloadState.remove(file)
        }

        func verified() throws -> Bool {
            guard RegionalDownloadState.regularSize(file) == expected.byteCount else { return false }
            return try RegionalDownloadState.hex(RegionalDownloadState.hash(file, byteCount: expected.byteCount))
                == expected.sha256
        }
    }

    private static let metadataLimit = 16_384
    let directory: URL
    var jobFile: URL { directory.appendingPathComponent("job.json") }
    var manifestFile: URL { directory.appendingPathComponent("manifest.json") }

    func prepare() throws {
        var folder = directory
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var attributes = URLResourceValues()
        attributes.isExcludedFromBackup = true
        try folder.setResourceValues(attributes)
    }

    func job() throws -> Job? {
        let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard let values else { return nil }
        guard values.isDirectory == true, values.isSymbolicLink == false else {
            throw RegionalBundleDownloadError.invalidCheckpoint
        }
        guard FileManager.default.fileExists(atPath: jobFile.path) else {
            try discard()
            return nil
        }
        let job = try Self.read(Job.self, from: jobFile)
        guard job.schemaVersion == 1, RegionalBundleManifest.isSHA256(job.manifestSHA256) else {
            throw RegionalBundleDownloadError.invalidCheckpoint
        }
        return job
    }

    func save(_ job: Job) throws { try Self.write(job, to: jobFile) }

    func asset(_ asset: RegionalBundleManifest.Asset, job: Job) -> Asset {
        Asset(file: directory.appendingPathComponent(asset.filename), manifestSHA256: job.manifestSHA256, expected: asset)
    }

    func discard() throws { try Self.remove(directory) }

    static func regularSize(_ file: URL) -> Int64? {
        guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink == false, let size = values.fileSize else { return nil }
        return Int64(size)
    }

    static func hash(_ file: URL, byteCount: Int64, cancellable: Bool = true) throws -> SHA256 {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        var remaining = byteCount
        while remaining > 0 {
            if cancellable { try Task.checkCancellation() }
            guard let bytes = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !bytes.isEmpty else {
                throw RegionalBundleDownloadError.invalidCheckpoint
            }
            hash.update(data: bytes)
            remaining -= Int64(bytes.count)
        }
        return hash
    }

    static func hex(_ hash: SHA256) -> String {
        hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func read<Value: Decodable>(_ type: Value.Type, from file: URL) throws -> Value {
        guard let size = regularSize(file), (1...Int64(metadataLimit)).contains(size),
              let input = try? FileHandle(forReadingFrom: file) else {
            throw RegionalBundleDownloadError.invalidCheckpoint
        }
        defer { try? input.close() }
        guard let bytes = try input.read(upToCount: metadataLimit + 1), bytes.count == size,
              let value = try? JSONDecoder().decode(type, from: bytes) else {
            throw RegionalBundleDownloadError.invalidCheckpoint
        }
        return value
    }

    private static func write<Value: Encodable>(_ value: Value, to file: URL) throws {
        let bytes = try JSONEncoder().encode(value)
        guard bytes.count <= metadataLimit else { throw RegionalBundleDownloadError.invalidCheckpoint }
        try bytes.write(to: file, options: .atomic)
    }

    private static func remove(_ file: URL) throws {
        do { try FileManager.default.removeItem(at: file) }
        catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {}
    }
}
