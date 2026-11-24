import CTFKReader
import Foundation

/// Read-only access to a local ZIM file.
public final class ZIMArchive {
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
        try (0..<entryCount).compactMap { index in
            try Task.checkCancellation()
            return try pdfEntry(at: index)
        }
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
        guard let resource = tfk_archive_article(archive, index, &error) else {
            if let error {
                throw Self.readError(error, fallback: "The archive article could not be read.")
            }
            return nil
        }
        return try Self.read(resource, maximumBytes: maximumBytes)
    }

    private static func read(_ resource: OpaquePointer, maximumBytes: Int? = nil) throws -> Resource {
        defer { tfk_resource_close(resource) }
        var count = 0
        guard let bytes = tfk_resource_bytes(resource, &count) else {
            throw ReadError(errorDescription: "The archive returned an unreadable resource.")
        }
        return Resource(
            path: String(cString: tfk_resource_path(resource)),
            title: String(cString: tfk_resource_title(resource)),
            mimeType: String(cString: tfk_resource_mime(resource)),
            data: Data(bytes: bytes, count: min(count, maximumBytes ?? count))
        )
    }

    private static func readError(_ error: UnsafeMutablePointer<CChar>?, fallback: String) -> ReadError {
        guard let error else { return ReadError(errorDescription: fallback) }
        defer { tfk_string_free(error) }
        return ReadError(errorDescription: String(cString: error))
    }
}
