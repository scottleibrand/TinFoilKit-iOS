import Foundation
import ZIMArchive

/// Admits only editions the bundled catalog explicitly permits Nearby to redistribute.
@MainActor
struct NearbyArchiveCatalog {
    private struct Edition {
        let pin: NearbyPublicManifest
        let pack: PublishedPack
    }

    private let downloads: PackDownloads
    private let library = InstalledLibrary.standard
    private let editions: [Edition]

    init(downloads: PackDownloads) {
        self.downloads = downloads
        var digests: Set<String> = []
        editions = PackCatalog.entries.compactMap { entry in
            let pack = entry.pack
            guard entry.allowsArchiveSharing, pack.source.pathExtension.lowercased() == "zim",
                  let bytes = Int(exactly: pack.sizeEstimate),
                  let pin = NearbyPublicManifest(id: pack.editionKey, byteCount: bytes, sha256: pack.sha256),
                  digests.insert(pack.sha256).inserted else { return nil }
            return Edition(pin: pin, pack: pack)
        }
    }

    var pins: [NearbyPublicManifest] { editions.map(\.pin) }

    func needs(_ pin: NearbyPublicManifest) async -> Bool {
        guard let edition = edition(for: pin), PackCatalog.bundledCopy(for: edition.pack) == nil,
              let installed = try? await library.archives(),
              !Task.isCancelled, downloads.canInstallLocalCopy(edition.pack) else { return false }
        // The library can already hold the same bytes under another catalog entry.
        return !installed.contains { $0.pack?.sha256 == pin.sha256 && $0.byteCount == edition.pack.sizeEstimate }
    }

    func source(_ pin: NearbyPublicManifest) async -> URL? {
        guard let edition = edition(for: pin) else { return nil }
        if let bundled = PackCatalog.bundledCopy(for: edition.pack) { return bundled }
        guard let installed = try? await library.archives() else { return nil }
        for archive in installed where archive.pack == edition.pack && archive.byteCount == edition.pack.sizeEstimate {
            let url = await library.fileURL(for: archive.id)
            guard !Task.isCancelled else { return nil }
            // The app-owned catalog install checked the digest. Check the current physical file
            // before serving it, and let the receiver verify all bytes against its own pin.
            if let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
               info.isRegularFile == true, info.isSymbolicLink != true, info.fileSize == pin.byteCount {
                return url
            }
        }
        return nil
    }

    func install(_ pin: NearbyPublicManifest, _ file: URL) async throws {
        guard let edition = edition(for: pin) else { throw InstallError.unlistedEdition }
        try await downloads.installNearbyArchive(edition.pack, from: file)
    }

    private func edition(for pin: NearbyPublicManifest) -> Edition? {
        editions.first { $0.pin == pin }
    }

    private enum InstallError: LocalizedError {
        case unlistedEdition

        var errorDescription: String? { "This archive is outside the verified Nearby catalog." }
    }
}
