import Foundation
import ZIMArchive

enum PortableLibraryFolder {
    struct Match: Identifiable, Sendable {
        let pack: PublishedPack
        let file: URL
        let bytes: Int64

        var id: String { pack.editionKey }
    }

    static func matchingPacks(in folder: URL, catalog: [PublishedPack]) throws -> [Match] {
        let accessed = folder.startAccessingSecurityScopedResource()
        defer { if accessed { folder.stopAccessingSecurityScopedResource() } }
        guard folder.isFileURL, try folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }

        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var filenames: Set<String> = []
        var matches: [Match] = []
        for pack in catalog {
            try Task.checkCancellation()
            let name = pack.source.lastPathComponent
            guard name.lowercased().hasSuffix(".zim"), !name.contains("/"), !name.contains("\\"),
                  filenames.insert(name).inserted else { continue }
            let file = folder.appendingPathComponent(name)
            guard let info = try? file.resourceValues(forKeys: keys),
                  info.isRegularFile == true, info.isSymbolicLink != true, let bytes = info.fileSize, bytes > 0 else { continue }
            matches.append(Match(pack: pack, file: file, bytes: Int64(bytes)))
        }
        return matches.sorted { ($0.bytes, $0.id) < ($1.bytes, $1.id) }
    }
}
