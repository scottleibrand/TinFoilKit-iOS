import CTFKReader
import Foundation

/// Read-only access to a local ZIM file.
public final class ZIMArchive {
    /// Inspect at most the given number of archive entries for PDF documents.
    public func pdfEntries(inspectingFirst maximumEntries: UInt32) throws -> [PDFEntry] {
        try (0..<min(entryCount, maximumEntries)).compactMap { index in
            try Task.checkCancellation()
            return try pdfEntry(at: index)
        }
    }

    public struct Resource: Sendable {
        public let path: String
        public let title: String
        public let mimeType: String
        public let data: Data
    }

    public struct PDFEntry: Identifiable, Sendable {
        public var id: String { path }
        public let path: String
        public let title: String
    }

    public struct ReadError: LocalizedError {
        public let errorDescription: String?
    }

    private let archive: OpaquePointer

    public init(fileURL: URL) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard fileURL.isFileURL else {
            throw ReadError(errorDescription: "A ZIM archive must be a local file.")
        }
        guard let archive = tfk_archive_open(fileURL.path, &error) else {
            throw Self.readError(error, fallback: "The ZIM archive could not be opened.")
        }
        self.archive = archive
    }

    deinit {
        tfk_archive_close(archive)
    }

    public var title: String? {
        guard let title = tfk_archive_title(archive) else { return nil }
        defer { tfk_string_free(title) }
        return String(cString: title)
    }

    public var entryCount: UInt32 {
        tfk_archive_entry_count(archive)
    }

    func verifyEmbeddedChecksum() throws {
        try Task.checkCancellation()
        if let error = tfk_archive_verify_checksum(archive) {
            throw Self.readError(error, fallback: "The ZIM checksum could not be verified.")
        }
        try Task.checkCancellation()
    }

    public func mainArticle() throws -> Resource {
        var error: UnsafeMutablePointer<CChar>?
        guard let resource = tfk_archive_main(archive, &error) else {
            throw Self.readError(error, fallback: "The archive has no main article.")
        }
        return try Self.read(resource)
    }

    public func resource(at path: String) throws -> Resource {
        guard !path.utf8.contains(0) else {
            throw ReadError(errorDescription: "An archive path cannot contain a null byte.")
        }
        var error: UnsafeMutablePointer<CChar>?
        guard let resource = tfk_archive_resource(archive, path, &error) else {
            throw Self.readError(error, fallback: "The archive entry was not found.")
        }
        return try Self.read(resource)
    }

    public struct DirectResourceInfo: Sendable {
        public let mimeType: String
        public let byteCount: Int
    }

    public func directResourceInfo(at path: String) throws -> DirectResourceInfo? {
        try withDirectResource(at: path) { resource in
            guard let count = Int(exactly: tfk_direct_resource_size(resource)) else {
                throw ReadError(errorDescription: "The archive resource is too large for this device.")
            }
            return DirectResourceInfo(mimeType: String(cString: tfk_direct_resource_mime(resource)),
                                      byteCount: count)
        }
    }

    public func directResourceBytes(at path: String, offset: Int, count: Int) throws -> Data {
        guard offset >= 0, (1...1_048_576).contains(count) else {
            throw ReadError(errorDescription: "The archive resource range is invalid.")
        }
        let data = try withDirectResource(at: path) { resource in
            var bytes = Data(count: count)
            var error: UnsafeMutablePointer<CChar>?
            let success = bytes.withUnsafeMutableBytes { buffer in
                tfk_direct_resource_read(resource, UInt64(offset), buffer.bindMemory(to: UInt8.self).baseAddress,
                                         count, &error)
            }
            guard success else { throw Self.readError(error, fallback: "The archive resource could not be read.") }
            return bytes
        }
        guard let data else { throw ReadError(errorDescription: "The archive resource cannot be read in ranges.") }
        return data
    }

    /// Writes a supported large compressed PDF into a caller-owned, empty temporary file.
    public func extractCompressedPDF(at path: String, to descriptor: Int32) throws -> Bool {
        guard !path.utf8.contains(0) else {
            throw ReadError(errorDescription: "An archive path cannot contain a null byte.")
        }
        try Task.checkCancellation()
        var error: UnsafeMutablePointer<CChar>?
        let status = tfk_archive_extract_compressed_pdf(archive, path, descriptor, { _ in
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }, nil, &error)
        if let error {
            let failure = Self.readError(error, fallback: "The compressed document could not be extracted.")
            try Task.checkCancellation()
            throw failure
        }
        try Task.checkCancellation()
        switch status {
        case 1: return true
        case 0: return false
        default: throw ReadError(errorDescription: "The compressed document could not be extracted.")
        }
    }

    private func withDirectResource<Value>(at path: String, _ operation: (OpaquePointer) throws -> Value) throws -> Value? {
        guard !path.utf8.contains(0) else {
            throw ReadError(errorDescription: "An archive path cannot contain a null byte.")
        }
        var error: UnsafeMutablePointer<CChar>?
        guard let resource = tfk_archive_direct_resource(archive, path, &error) else {
            if let error { throw Self.readError(error, fallback: "The archive resource could not be opened.") }
            return nil
        }
        defer { tfk_direct_resource_close(resource) }
        return try operation(resource)
    }

    /// Follows redirects without loading resource bytes. Returns nil if the requested path is absent.
    public func resolvedPath(at path: String) throws -> String? {
        guard !path.utf8.contains(0) else {
            throw ReadError(errorDescription: "An archive path cannot contain a null byte.")
        }
        var error: UnsafeMutablePointer<CChar>?
        guard let resolved = tfk_archive_resolved_path(archive, path, &error) else {
            if let error { throw Self.readError(error, fallback: "The archive entry could not be resolved.") }
            return nil
        }
        defer { tfk_string_free(resolved) }
        return String(cString: resolved)
    }

    public func article(at index: UInt32) throws -> Resource? {
        try article(at: index, maximumBytes: nil)
    }

    /// Search article titles using the publisher's embedded listing, without reading article bodies.
    public func articleTitles(matching query: String) throws -> [ArticleTitle] {
        let prefix = query.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !prefix.isEmpty, prefix.utf8.count <= 512, !prefix.utf8.contains(0) else { return [] }
        let lowercase = prefix.lowercased()
        let sentenceCase = lowercase.prefix(1).uppercased() + lowercase.dropFirst()
        var prefixes: Set<String> = []
        var paths: Set<String> = []
        var titles: [ArticleTitle] = []
        for spelling in [prefix, sentenceCase, lowercase] where prefixes.insert(spelling).inserted {
            try Task.checkCancellation()
            var error: UnsafeMutablePointer<CChar>?
            guard let matches = tfk_archive_title_prefix(archive, spelling, &error) else {
                throw Self.readError(error, fallback: "The archive titles could not be read.")
            }
            defer { tfk_title_matches_close(matches) }
            for index in 0..<30 {
                guard let entry = tfk_title_matches_entry(matches, index) else { break }
                let path = String(cString: tfk_entry_metadata_path(entry))
                guard paths.insert(path).inserted else { continue }
                let title = String(cString: tfk_entry_metadata_title(entry))
                titles.append(ArticleTitle(path: path, title: title.isEmpty ? path : title))
                if titles.count == 30 { return titles }
            }
        }
        return titles
    }

    public struct ArticleTitle: Sendable {
        public let path: String
        public let title: String
    }

    public func pdfEntries() throws -> [PDFEntry] {
        try pdfEntries(inspectingFirst: entryCount)
    }

    func pdfEntry(at index: UInt32) throws -> PDFEntry? {
        var error: UnsafeMutablePointer<CChar>?
        guard let entry = tfk_archive_pdf_entry(archive, index, &error) else {
            if let error {
                throw Self.readError(error, fallback: "The archive document could not be read.")
            }
            return nil
        }
        defer { tfk_entry_metadata_close(entry) }
        let path = String(cString: tfk_entry_metadata_path(entry))
        let title = String(cString: tfk_entry_metadata_title(entry))
        return PDFEntry(path: path, title: title.isEmpty ? path : title)
    }

    func article(at index: UInt32, maximumBytes: Int?) throws -> Resource? {
        var error: UnsafeMutablePointer<CChar>?
        let resource = if let maximumBytes {
            tfk_archive_article_prefix(archive, index, max(0, maximumBytes), &error)
        } else {
            tfk_archive_article(archive, index, &error)
        }
        guard let resource else {
            if let error {
                throw Self.readError(error, fallback: "The archive article could not be read.")
            }
            return nil
        }
        return try Self.read(resource)
    }

    private static func read(_ resource: OpaquePointer) throws -> Resource {
        defer { tfk_resource_close(resource) }
        var count = 0
        guard let bytes = tfk_resource_bytes(resource, &count) else {
            throw ReadError(errorDescription: "The archive returned an unreadable resource.")
        }
        return Resource(
            path: String(cString: tfk_resource_path(resource)),
            title: String(cString: tfk_resource_title(resource)),
            mimeType: String(cString: tfk_resource_mime(resource)),
            data: Data(bytes: bytes, count: count)
        )
    }

    private static func readError(_ error: UnsafeMutablePointer<CChar>?, fallback: String) -> ReadError {
        guard let error else { return ReadError(errorDescription: fallback) }
        defer { tfk_string_free(error) }
        return ReadError(errorDescription: String(cString: error))
    }
}
