import CryptoKit
import Foundation

/// Storage for one public catalog edition. Only the exact pinned bytes can enter it.
struct NearbyPublicReference: Sendable {
    struct Entry: Equatable, Sendable {
        let manifest: NearbyPublicManifest
        let title: String

        var id: String { manifest.id }
        fileprivate var resumePin: String { "\(id)-\(manifest.sha256)" }
    }

    static let worksheet = Entry(
        manifest: NearbyPublicManifest(
            id: "household-check-in-v1", byteCount: 1_977,
            sha256: "4a3386d0c610571465db46352f3f395d768867e899e711de363b42cae4a9b18c"
        )!,
        title: "Household check-in worksheet"
    )
    static let mainCatalog: [Entry] = [
        worksheet,
        Entry(
            manifest: NearbyPublicManifest(
                id: "neighborhood-status-log-v1", byteCount: 2_219,
                sha256: "965c18d24c359b38e481b12d172a97f704208540260bc7900cd7c6d01ab71411"
            )!,
            title: "Neighborhood status log"
        )
    ]

    // The original worksheet entry points are also used by the Darwin fixtures.
    static let id = worksheet.id
    static let title = worksheet.title
    static let expectedByteCount = worksheet.manifest.byteCount
    static let resumePin = worksheet.resumePin

    static var catalogReferences: [Self] {
        mainCatalog.map { entry in
            Self(entry: entry, bundledFile: Bundle.main.url(forResource: entry.id, withExtension: "txt"))
        }
    }

    let entry: Entry
    private let directory: URL
    private let bundledFile: URL?
    private let availableCapacity: @Sendable (URL) -> Int64?

    var resumePin: String { entry.resumePin }

    private static let defaultDirectory = URL.applicationSupportDirectory
        .appendingPathComponent("NearbyPublic", isDirectory: true)

    init(
        directory: URL = NearbyPublicReference.defaultDirectory,
        bundledFile: URL? = Bundle.main.url(forResource: NearbyPublicReference.id, withExtension: "txt"),
        availableCapacity: @escaping @Sendable (URL) -> Int64? = { NearbyPublicReference.volumeCapacity(at: $0) }
    ) {
        self.init(entry: Self.worksheet, directory: directory, bundledFile: bundledFile,
                  availableCapacity: availableCapacity)
    }

    init(
        entry: Entry,
        directory: URL = NearbyPublicReference.defaultDirectory,
        bundledFile: URL? = nil,
        availableCapacity: @escaping @Sendable (URL) -> Int64? = { NearbyPublicReference.volumeCapacity(at: $0) }
    ) {
        self.entry = entry
        self.directory = directory
        self.bundledFile = bundledFile
        self.availableCapacity = availableCapacity
    }

    func loadVerified() -> Data? {
        if let bundledFile, let bytes = readVerified(at: bundledFile) { return bytes }
        return readVerified(at: receivedFile)
    }

    func admission() -> NearbyPublicManifest.Admission {
        let manifest = entry.manifest
        let verified: Set<String> = loadVerified() == nil ? [] : [manifest.sha256]
        return manifest.admit(manifest, verifiedDigests: verified, availableBytes: storageCapacity())
    }

    private func storageCapacity() -> Int64? {
        let manager = FileManager.default
        var ancestor = directory
        while !manager.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return nil }
            ancestor = parent
        }
        return availableCapacity(ancestor)
    }

    func receiveVerified(_ data: Data) throws -> Bool {
        guard matches(data) else { throw StoreError.invalidReference }
        switch admission() {
        case .alreadyInstalled: return false
        case .receive: break
        case .unlisted: throw StoreError.invalidReference
        case .insufficientStorage: throw StoreError.insufficientStorage
        }
        try prepareDirectory()
        let decision = admission()
        if decision == .alreadyInstalled { return false }
        guard decision == .receive else { throw StoreError.insufficientStorage }
        try data.write(to: receivedFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        return true
    }

    private func prepareDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
    }

    // The filename binds the prefix to this exact catalog edition and digest.
    private var checkpointFile: URL {
        directory.appendingPathComponent("\(resumePin).partial")
    }

    func checkpoint() -> Data {
        NearbyPublicResume.load(from: checkpointFile, byteCount: entry.manifest.byteCount)
    }

    func saveCheckpoint(_ data: Data) throws {
        guard (1..<entry.manifest.byteCount).contains(data.count) else { throw StoreError.invalidReference }
        guard admission() == .receive else { throw StoreError.insufficientStorage }
        try prepareDirectory()
        try data.write(to: checkpointFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func removeCheckpoint() {
        try? FileManager.default.removeItem(at: checkpointFile)
    }

    private var receivedFile: URL {
        directory.appendingPathComponent(entry.id).appendingPathExtension("txt")
    }

    private func readVerified(at url: URL) -> Data? {
        let size = entry.manifest.byteCount
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == size, size < Int.max,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: size + 1), matches(bytes) else { return nil }
        return bytes
    }

    private func matches(_ bytes: Data) -> Bool {
        bytes.count == entry.manifest.byteCount &&
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == entry.manifest.sha256
    }

    private static func volumeCapacity(at url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
           let capacity = values.volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let values = try? FileManager.default.attributesOfFileSystem(forPath: url.path)
        return (values?[.systemFreeSize] as? NSNumber)?.int64Value
    }

    enum StoreError: LocalizedError, Equatable {
        case invalidReference
        case insufficientStorage

        var errorDescription: String? {
            switch self {
            case .invalidReference: "The shared reference failed verification."
            case .insufficientStorage: "Free up storage to receive the public reference."
            }
        }
    }
}
