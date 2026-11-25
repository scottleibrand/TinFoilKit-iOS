import Foundation
import ZIMArchive

struct KiwixDownloadApproval: Codable, Equatable, Sendable {
    let pack: PublishedPack
    let allowsCellular: Bool
    var replacement: Replacement? = nil

    struct Replacement: Codable, Equatable, Sendable {
        let archiveID: UUID
        let source: URL
    }

    var replacesArchiveID: UUID? { replacement?.archiveID }

    static func replacement(for candidate: PublishedPack, in seriesPack: PublishedPack) -> PublishedPack? {
        guard isValid(candidate),
              let series = KiwixCatalog.EditionSeries(archiveURL: seriesPack.source),
              series.newerEdition(at: candidate.source) == candidate.version else { return nil }
        return PublishedPack(id: seriesPack.id, title: seriesPack.title, version: candidate.version,
                             source: candidate.source, sha256: candidate.sha256, sizeEstimate: candidate.sizeEstimate,
                             attribution: candidate.attribution)
    }

    static func pack(for book: KiwixCatalog.Book, metadata: KiwixMetalink) -> PublishedPack? {
        let source = book.archiveURL
        guard metadata.filename == source.lastPathComponent else { return nil }
        let attribution = book.creator.isEmpty ? "Archive distributed by Kiwix"
            : "\(book.creator) · archive distributed by Kiwix"
        let pack = PublishedPack(id: "kiwix-\(metadata.sha256)", title: book.title, version: version(for: source),
                                 source: source, sha256: metadata.sha256, sizeEstimate: metadata.byteCount,
                                 attribution: attribution)
        return isValid(pack) ? pack : nil
    }

    static func isValid(_ pack: PublishedPack) -> Bool {
        pack.id == "kiwix-\(pack.sha256)" && hasValidMetadata(pack)
    }

    private static func hasValidMetadata(_ pack: PublishedPack) -> Bool {
        KiwixCatalog.isTrustedArchiveURL(pack.source)
            && pack.version == version(for: pack.source)
            && pack.sha256.utf8.count == 64 && pack.sha256.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
            && pack.sizeEstimate > 0 && pack.sizeEstimate <= Int64.max / 2
            && !pack.title.isEmpty && pack.title.count <= 256
            && !pack.attribution.isEmpty && pack.attribution.count <= 300
    }

    private var isValid: Bool {
        guard let replacement else { return Self.isValid(pack) }
        return Self.hasValidMetadata(pack)
            && pack.id.range(of: #"^[a-zA-Z0-9_-]{1,150}$"#, options: .regularExpression) != nil
            && KiwixCatalog.EditionSeries(archiveURL: replacement.source)?.newerEdition(at: pack.source) == pack.version
    }

    private static func version(for source: URL) -> String {
        let suffix = String(source.deletingPathExtension().lastPathComponent.suffix(7))
        return suffix.range(of: #"^[0-9]{4}-[0-9]{2}$"#, options: .regularExpression) == nil
            ? "publisher-edition" : suffix
    }

    private static let fileExtension = "publisher-approval"
    private static let maximumApprovalBytes = 16_384

    private func file(in directory: URL) -> URL {
        directory.appendingPathComponent(pack.editionKey).appendingPathExtension(Self.fileExtension)
    }

    func save(in directory: URL) throws {
        guard isValid else { throw KiwixMetalink.ParseError.invalidMetadata }
        let data = try JSONEncoder().encode(self)
        guard data.count <= Self.maximumApprovalBytes else { throw KiwixMetalink.ParseError.invalidMetadata }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: file(in: directory), options: .atomic)
    }

    func remove(from directory: URL) throws {
        try FileManager.default.removeItem(at: file(in: directory))
    }

    static func load(from directory: URL) -> [String: Self] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        var approvals: [String: Self] = [:]
        for file in files where file.pathExtension == fileExtension {
            guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumApprovalBytes,
                  let data = try? Data(contentsOf: file),
                  let approval = try? JSONDecoder().decode(Self.self, from: data), approval.isValid,
                  file.deletingPathExtension().lastPathComponent == approval.pack.editionKey else { continue }
            approvals[approval.pack.editionKey] = approval
        }
        return approvals
    }
}
