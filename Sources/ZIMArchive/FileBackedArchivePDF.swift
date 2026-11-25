import CryptoKit
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
    /// Opens a PDF and optionally validates the exact source bytes before handing them to PDFKit.
    public func pdfDocument(at path: String, expectedSHA256: String? = nil) throws -> PDFDocument? {
        if let temporary = try prepareLargePDF(at: path) {
            if let expectedSHA256 {
                let input = try FileHandle(forReadingFrom: temporary.url)
                defer { try? input.close() }
                var digest = SHA256()
                while let bytes = try input.read(upToCount: 1_048_576), !bytes.isEmpty {
                    try Task.checkCancellation()
                    digest.update(data: bytes)
                }
                guard Self.hexDigest(digest.finalize()) == expectedSHA256 else { return nil }
            }
            try Task.checkCancellation()
            return FileBackedArchivePDF(temporary)
        }
        let resource = try resource(at: path)
        try Task.checkCancellation()
        guard resource.mimeType == "application/pdf",
              expectedSHA256.map({ $0 == Self.hexDigest(SHA256.hash(data: resource.data)) }) ?? true else {
            return nil
        }
        return PDFDocument(data: resource.data)
    }

    private static func hexDigest(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

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
