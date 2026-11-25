import Foundation

struct RegionalBundleDownloadSource: Sendable {
    static let maximumURLBytes = 4_096

    let url: URL
    let sha256: String

    init(url: String, sha256: String) throws {
        let address = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = sha256.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard address.utf8.count <= Self.maximumURLBytes, let parsed = URL(string: address),
              parsed.absoluteString.utf8.count <= Self.maximumURLBytes, RegionalBundleManifest.isHTTPS(parsed),
              RegionalBundleManifest.isSHA256(digest) else { throw RegionalBundleDownloadError.invalidSource }
        self.url = parsed
        self.sha256 = digest
    }
}

enum RegionalBundleDownloadError: LocalizedError, Equatable {
    case invalidSource, busy, manifestDigest, catalogMismatch, size, response, incomplete, storage
    case pendingDownload, invalidCheckpoint
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .invalidSource:
            "Enter an HTTPS manifest URL and the 64-character SHA-256 from a trusted source."
        case .busy:
            "A regional download is already running."
        case .manifestDigest:
            "The downloaded manifest did not match the trusted SHA-256."
        case .catalogMismatch:
            "The verified manifest does not match this catalog region, edition, or download size."
        case .size:
            "The response is larger than the permitted download or has the wrong size."
        case .response:
            "The publisher did not return the requested file over HTTPS."
        case .incomplete:
            "The transfer ended before all of the file arrived. Retry to continue."
        case .storage:
            "Free some storage for the download and the installed regional bundle, then retry."
        case .pendingDownload:
            "Resume or discard the pending regional download before starting another one."
        case .invalidCheckpoint:
            "The saved regional download could not be verified. Discard it to start again."
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

    struct Pending: Sendable {
        let manifest: RegionalBundleManifest
        let cellular: Bool
        let started: Bool
    }

    static let shared = RegionalBundleDownload(directory: URL.applicationSupportDirectory
        .appendingPathComponent("PendingRegionalDownload", isDirectory: true))
    private let state: RegionalDownloadState
    private var busy = false

    init(directory: URL) {
        state = RegionalDownloadState(directory: directory)
    }

    func pending() throws -> Pending? {
        guard !busy else { throw RegionalBundleDownloadError.busy }
        guard let job = try state.job() else { return nil }
        return try pending(for: job)
    }

    func load(_ source: RegionalBundleDownloadSource, cellular: Bool) async throws -> Pending {
        try await load(source, cellular: cellular, catalogEntry: nil)
    }

    func load(_ entry: RegionalBundleCatalog.Entry, cellular: Bool) async throws -> Pending {
        try await load(entry.source, cellular: cellular, catalogEntry: entry)
    }

    private func load(_ source: RegionalBundleDownloadSource, cellular: Bool,
                      catalogEntry: RegionalBundleCatalog.Entry?) async throws -> Pending {
        guard !busy else { throw RegionalBundleDownloadError.busy }
        guard try state.job() == nil else { throw RegionalBundleDownloadError.pendingDownload }
        busy = true
        defer { busy = false }
        var committed = false
        defer { if !committed { try? state.discard() } }
        try state.prepare()

        let outcome = await RegionalBundleTransfer.receive(
            source.url, to: state.manifestFile, limit: Int64(RegionalBundleManifest.maximumManifestBytes),
            size: nil, cellular: cellular
        ) { _ in }
        try Task.checkCancellation()
        if let error = outcome.error { throw error }
        let job = RegionalDownloadState.Job(source: source, cellular: cellular)
        let pending = try pending(for: job)
        if let catalogEntry, !catalogEntry.matches(pending.manifest) {
            throw RegionalBundleDownloadError.catalogMismatch
        }
        try state.save(job)
        committed = true
        return pending
    }

    func discard() throws {
        guard !busy else { throw RegionalBundleDownloadError.busy }
        try state.discard()
    }

    func install(in storage: RegionalBundleStorage,
                 progress: @escaping @Sendable (Progress) -> Void) async throws -> RegionalBundleStorage.Installed {
        guard !busy else { throw RegionalBundleDownloadError.busy }
        guard var job = try state.job() else { throw RegionalBundleDownloadError.invalidCheckpoint }
        let manifest = try pending(for: job).manifest
        busy = true
        defer { busy = false }
        let installedBundles = try await storage.installedBundles()
        try Task.checkCancellation()
        if let installed = installedBundles.first(where: { $0.isUsable && $0.manifest == manifest }) {
            try? state.discard()
            return installed
        }
        job.started = true
        try state.save(job)

        let assets = manifest.assets.downloadFiles.map { state.asset($0, job: job) }
        let total = manifest.assets.downloadByteCount
        let (stagingBytes, stagingOverflow) = total.addingReportingOverflow(manifest.assets.routing.byteCount)
        let remaining = assets.reduce(Int64(0)) { total, asset in
            let size = RegionalDownloadState.regularSize(asset.file) ?? 0
            return total + asset.expected.byteCount - min(size, asset.expected.byteCount)
        }
        let (needed, totalOverflow) = stagingBytes.addingReportingOverflow(remaining)
        guard !stagingOverflow, !totalOverflow else { throw RegionalBundleDownloadError.storage }
        if let available = try state.directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, available < needed { throw RegionalBundleDownloadError.storage }

        var previousBytes: Int64 = 0
        for asset in assets {
            let base = previousBytes
            try await fetch(asset, cellular: job.cellular) { offset in
                progress(.receiving(asset.expected.filename, base + offset, total))
            }
            previousBytes += asset.expected.byteCount
        }
        try Task.checkCancellation()
        progress(.installing)
        let installed = try await storage.install(state.directory)
        try? state.discard()
        return installed
    }

    private func pending(for job: RegionalDownloadState.Job) throws -> Pending {
        guard let size = RegionalDownloadState.regularSize(state.manifestFile),
              (1...Int64(RegionalBundleManifest.maximumManifestBytes)).contains(size) else {
            throw RegionalBundleDownloadError.invalidCheckpoint
        }
        let hash = try RegionalDownloadState.hash(state.manifestFile, byteCount: size)
        guard RegionalDownloadState.hex(hash) == job.manifestSHA256 else {
            throw RegionalBundleDownloadError.manifestDigest
        }
        let manifest = try RegionalBundleManifest.read(from: state.manifestFile)
        return Pending(manifest: manifest, cellular: job.cellular, started: job.started)
    }

    private func fetch(_ asset: RegionalDownloadState.Asset, cellular: Bool,
                       progress: @escaping @Sendable (Int64) -> Void) async throws {
        try Task.checkCancellation()
        let expected = asset.expected
        if try asset.verified() {
            progress(expected.byteCount)
            return
        }
        let resume = try asset.resume()
        if resume == nil { try asset.reset() }
        let offset = resume?.offset ?? 0
        progress(offset)
        let outcome = await RegionalBundleTransfer.receive(
            expected.url, to: asset.file, limit: expected.byteCount, size: expected.byteCount,
            cellular: cellular, resume: resume, checkpoint: asset, progress: progress
        )
        try Task.checkCancellation()
        if let error = outcome.error { throw error }
        guard try asset.verified() else {
            try asset.reset()
            throw RegionalBundleManifest.Error.invalidArtifact(expected.filename)
        }
    }
}
