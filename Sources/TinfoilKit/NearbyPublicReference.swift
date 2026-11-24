import CryptoKit
import Foundation

/// The first public item known to both builds. Only these exact bytes can enter this store.
struct NearbyPublicReference: Sendable {
    static let id = "household-check-in-v1"
    static let title = "Household check-in worksheet"
    static let expectedByteCount = 1_977

    private static let sha256 = "4a3386d0c610571465db46352f3f395d768867e899e711de363b42cae4a9b18c"
    private static let minimumFreeBytes = Int64(1_048_576 + 2 * expectedByteCount)

    private let directory: URL
    private let bundledFile: URL?
    private let availableCapacity: @Sendable (URL) -> Int64?

    init(
        directory: URL = .applicationSupportDirectory.appendingPathComponent("NearbyPublic", isDirectory: true),
        bundledFile: URL? = Bundle.main.url(forResource: NearbyPublicReference.id, withExtension: "txt"),
        availableCapacity: @escaping @Sendable (URL) -> Int64? = { NearbyPublicReference.volumeCapacity(at: $0) }
    ) {
        self.directory = directory
        self.bundledFile = bundledFile
        self.availableCapacity = availableCapacity
    }

    func loadVerified() -> Data? {
        if let bundledFile, let bytes = Self.readVerified(at: bundledFile) { return bytes }
        return Self.readVerified(at: receivedFile)
    }

    func canReceive() -> Bool {
        let manager = FileManager.default
        var ancestor = directory
        while !manager.fileExists(atPath: ancestor.path) {
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return false }
            ancestor = parent
        }
        return (availableCapacity(ancestor) ?? 0) >= Self.minimumFreeBytes
    }

    func receiveVerified(_ data: Data) throws {
        guard Self.matches(data) else { throw StoreError.invalidReference }
        guard loadVerified() == nil else { return }
        guard canReceive() else { throw StoreError.insufficientStorage }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var folder = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try folder.setResourceValues(values)
        guard canReceive() else { throw StoreError.insufficientStorage }
        try data.write(to: receivedFile, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private var receivedFile: URL {
        directory.appendingPathComponent(Self.id).appendingPathExtension("txt")
    }

    private static func readVerified(at url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true,
              values.fileSize == Self.expectedByteCount,
              let file = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: Self.expectedByteCount + 1), matches(bytes) else { return nil }
        return bytes
    }

    private static func matches(_ bytes: Data) -> Bool {
        bytes.count == Self.expectedByteCount &&
            SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() == Self.sha256
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
