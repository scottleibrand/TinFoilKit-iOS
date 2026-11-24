import Foundation
import ZIMArchive

enum PackCatalog {
    enum Section: String, CaseIterable, Decodable {
        case essentials, topics, extended

        var title: String {
            switch self {
            case .essentials: "Essentials"
            case .topics: "Wikipedia topics"
            case .extended: "Extended library"
            }
        }
    }

    enum Language: String, CaseIterable, Decodable {
        case english = "en"
        case spanish = "es"

        var title: String {
            switch self {
            case .english: "English"
            case .spanish: "Español"
            }
        }
    }

    struct Entry: Identifiable, Decodable {
        let pack: PublishedPack
        let section: Section
        let language: Language
        let isDefault: Bool
        let individualDownloadOnly: Bool?
        let detail: String?
        let termsURL: URL?
        let usesPDFDirectory: Bool
        let allowsArchiveSharing: Bool

        var id: String { pack.editionKey }
        var isBulkEligible: Bool { isDefault && individualDownloadOnly != true }
    }

    static let entries = (try? bundled.get()) ?? []

    static var loadError: String? {
        if case let .failure(error) = bundled { return error.localizedDescription }
        return nil
    }

    private static let bundled = Result {
        guard let url = Bundle.main.url(forResource: "PackCatalog", withExtension: "json") else {
            throw CatalogError.missingResource
        }
        return try load(from: url)
    }

    static func load(from url: URL) throws -> [Entry] {
        let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))
        let series = Set(entries.map(\.pack.id))
        let defaults = entries.filter(\.isDefault).map(\.pack.id)
        guard !entries.isEmpty, Set(entries.map(\.id)).count == entries.count,
              Set(defaults) == series, defaults.count == series.count,
              entries.allSatisfy(hasValidMetadata) else {
            throw CatalogError.invalidMetadata
        }
        return entries
    }

    private static func hasValidMetadata(_ entry: Entry) -> Bool {
        let pack = entry.pack
        let safeFilePart: (String) -> Bool = { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        }
        return safeFilePart(pack.id) && safeFilePart(pack.version)
            && !pack.title.isEmpty && !pack.attribution.isEmpty && pack.sizeEstimate > 0
            && pack.source.scheme == "https" && pack.source.host != nil
            && pack.sha256.utf8.count == 64 && pack.sha256.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            }
    }

    private enum CatalogError: LocalizedError {
        case missingResource, invalidMetadata

        var errorDescription: String? {
            switch self {
            case .missingResource: "The bundled content pack catalog could not be found."
            case .invalidMetadata: "The bundled content pack catalog has invalid metadata."
            }
        }
    }
}
