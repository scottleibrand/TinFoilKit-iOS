import CryptoKit
import Foundation

struct RegionalBundleDownloadSource: Sendable {
    let url: URL
    let sha256: String

    init(url: String, sha256: String) throws {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let parsed = URL(string: address), RegionalBundleManifest.isHTTPS(parsed),
              RegionalBundleManifest.isSHA256(digest) else { throw RegionalBundleDownloadError.invalidSource }
        self.url = parsed
        self.sha256 = digest
    }
}

enum RegionalBundleDownloadError: LocalizedError, Equatable {
    case invalidSource, busy, manifestDigest, size, response, incomplete, storage
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            "Enter an HTTPS manifest URL and the 64-character SHA-256 from a trusted source."
        case .busy:
            "A regional download is already running."
        case .manifestDigest:
            "The downloaded manifest did not match the trusted SHA-256."
        case .size:
            "The response is larger than the permitted download or has the wrong size."
        case .response:
            "The publisher did not return the requested file over HTTPS."
        case .incomplete:
            "The transfer ended before all of the file arrived. Retry to continue."
        case .storage:
            "Free some storage for the download and the installed regional bundle, then retry."
        case .http(let status):
            "The publisher returned HTTP \(status)."
        }
    }
}

actor RegionalBundleDownload {
    enum Progress: Sendable {
        case receiving(String, Int64, Int64)
        case installing
    }

    private let directory = URL.temporaryDirectory.appendingPathComponent("RegionalDownload-\(UUID().uuidString)",
                                                                          isDirectory: true)
    private var validators: [String: String] = [:]
    private var manifest: RegionalBundleManifest?
    private var busy = false

    deinit { try? FileManager.default.removeItem(at: directory) }

    func load(_ source: RegionalBundleDownloadSource, cellular: Bool) async throws -> RegionalBundleManifest {
        guard !busy else { throw RegionalBundleDownloadError.busy }
        busy = true
        defer { busy = false }
        manifest = nil
        validators.removeAll()
        let files = FileManager.default
        if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("manifest.json")
        let outcome = await RegionalBundleTransfer.receive(
            source.url, to: file, limit: Int64(RegionalBundleManifest.maximumManifestBytes),
            size: nil, offset: 0, validator: nil, cellular: cellular
        ) { _ in }
        try Task.checkCancellation()
        if let error = outcome.error { throw error }
        guard try Self.digest(file) == source.sha256 else { throw RegionalBundleDownloadError.manifestDigest }
        let validated = try RegionalBundleManifest.read(from: file)
        manifest = validated
        return validated
    }

    func install(in storage: RegionalBundleStorage, cellular: Bool,
                 progress: @escaping @Sendable (Progress) -> Void) async throws -> RegionalBundleStorage.Installed {
        guard !busy else { throw RegionalBundleDownloadError.busy }
        guard let manifest else { throw RegionalBundleManifest.Error.invalidManifest }
        busy = true
        defer { busy = false }
        let assets = manifest.assets.downloadFiles
        let total = manifest.assets.downloadByteCount
        let (stagingBytes, stagingOverflow) = total.addingReportingOverflow(manifest.assets.routing.byteCount)
        let remaining = assets.reduce(Int64(0)) { $0 + $1.byteCount - savedSize(of: $1) }
        let (needed, totalOverflow) = stagingBytes.addingReportingOverflow(remaining)
        guard !stagingOverflow, !totalOverflow else { throw RegionalBundleDownloadError.storage }
        if let available = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, available < needed { throw RegionalBundleDownloadError.storage }

        var previousBytes: Int64 = 0
        for asset in assets {
            let base = previousBytes
            try await fetch(asset, cellular: cellular) { offset in
                progress(.receiving(asset.filename, base + offset, total))
            }
            previousBytes += asset.byteCount
        }
        try Task.checkCancellation()
        progress(.installing)
        let installed = try await storage.install(directory)
        try? FileManager.default.removeItem(at: directory)
        self.manifest = nil
        validators.removeAll()
        return installed
    }

    private func savedSize(of asset: RegionalBundleManifest.Asset) -> Int64 {
        let file = directory.appendingPathComponent(asset.filename)
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        return (0...asset.byteCount).contains(size) ? size : 0
    }

    private func fetch(_ asset: RegionalBundleManifest.Asset, cellular: Bool,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        try Task.checkCancellation()
        let file = directory.appendingPathComponent(asset.filename)
        if savedSize(of: asset) == asset.byteCount, try Self.digest(file) == asset.sha256 {
            progress(asset.byteCount)
            return
        }
        let validator = validators[asset.filename]
        let saved = savedSize(of: asset)
        let offset = validator != nil && saved < asset.byteCount ? saved : 0
        progress(offset)
        let outcome = await RegionalBundleTransfer.receive(
            asset.url, to: file, limit: asset.byteCount, size: asset.byteCount,
            offset: offset, validator: validator, cellular: cellular, progress: progress
        )
        validators[asset.filename] = outcome.validator
        if let error = outcome.error {
            if outcome.validator == nil { try? FileManager.default.removeItem(at: file) }
            try Task.checkCancellation()
            throw error
        }
        try Task.checkCancellation()
        guard try Self.digest(file) == asset.sha256 else {
            validators[asset.filename] = nil
            try? FileManager.default.removeItem(at: file)
            throw RegionalBundleManifest.Error.invalidArtifact(asset.filename)
        }
    }

    private static func digest(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        while let bytes = try input.read(upToCount: 1024 * 1024), !bytes.isEmpty {
            try Task.checkCancellation()
            hash.update(data: bytes)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
