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
        var error: UnsafeMutablePointer<CChar>?
        guard let resource = tfk_archive_article(archive, index, &error) else {
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
