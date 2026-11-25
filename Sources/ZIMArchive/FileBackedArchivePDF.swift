import Foundation
import PDFKit

public final class TemporaryArchivePDF: Sendable {
    public let url: URL

    init(url: URL) { self.url = url }

    deinit { try? FileManager.default.removeItem(at: url) }
}

public final class FileBackedArchivePDF: PDFDocument {
    private let temporary: TemporaryArchivePDF

    public init?(_ temporary: TemporaryArchivePDF) {
        self.temporary = temporary
        super.init(url: temporary.url)
    }
}

extension ZIMArchive {
    /// Opens supported large PDF entries from a file instead of a single buffer.
    public func prepareLargePDF(at path: String) throws -> TemporaryArchivePDF? {
        let info = try directResourceInfo(at: path)
        let directory = URL.temporaryDirectory
        if let info {
            guard info.mimeType == "application/pdf", info.byteCount > 32 * 1024 * 1024 else { return nil }
            let capacity = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            if let available = capacity.volumeAvailableCapacityForImportantUsage, available < Int64(info.byteCount) {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }
        try Task.checkCancellation()
        let temporary = TemporaryArchivePDF(url: directory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf"))
        guard FileManager.default.createFile(atPath: temporary.url.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let output = try FileHandle(forWritingTo: temporary.url)
        defer { try? output.close() }
        if let info {
            var offset = 0
            while offset < info.byteCount {
                try Task.checkCancellation()
                let count = min(1_048_576, info.byteCount - offset)
                try output.write(contentsOf: directResourceBytes(at: path, offset: offset, count: count))
                offset += count
            }
        } else if try !extractCompressedPDF(at: path, to: output.fileDescriptor) {
            return nil
        }
        try output.close()
        try Task.checkCancellation()
        return temporary
    }
}
