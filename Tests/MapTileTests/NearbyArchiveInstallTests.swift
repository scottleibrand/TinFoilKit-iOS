import CryptoKit
import Foundation
import XCTest
import ZIMArchive
@testable import TinfoilKit

final class NearbyArchiveInstallTests: XCTestCase {
    func testVerifiedStagingFileInstallsAndItsPDFPagesBecomeSearchable() async throws {
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pdf-collection", withExtension: "zim"))
        let bytes = try Data(contentsOf: fixture)
        let size = UInt64(bytes.count)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = NearbyArchiveFiles(directory: root.appendingPathComponent("stage"))
        let offset = try await files.prepare(digest: digest, byteCount: size, availableBytes: Int64.max)
        XCTAssertEqual(offset, 0)
        for start in stride(from: 0, to: bytes.count, by: NearbyArchiveFiles.chunkBytes) {
            let end = min(start + NearbyArchiveFiles.chunkBytes, bytes.count)
            _ = try await files.append(bytes[start..<end], at: UInt64(start), digest: digest, byteCount: size)
        }

        let verified = try await files.verifiedFile(digest: digest, byteCount: size)
        let library = InstalledLibrary(directory: root.appendingPathComponent("Library"))
        let pack = PublishedPack(id: "nearby-fixture", title: "Nearby PDF fixture", version: "1",
                                 source: URL(string: "https://example.invalid/nearby.zim")!, sha256: digest,
                                 sizeEstimate: Int64(size), attribution: "Tinfoil Kit synthetic fixture")
        let archive = try await library.installDownloadedPublishedPack(pack, from: verified)
        XCTAssertFalse(FileManager.default.fileExists(atPath: verified.path))
        let reopened = try await library.archives()
        XCTAssertEqual(reopened, [archive])

        let installed = await library.fileURL(for: archive.id)
        let index = ArticleIndex(archiveURL: installed)
        try index.build(archiveURL: installed)
        let match = try XCTUnwrap(index.search("protozoa").first)
        let pdf = try XCTUnwrap(ArchivePDFReference(articlePath: match.path))
        XCTAssertEqual(pdf.path, "files/Water Guide.pdf")
        XCTAssertEqual(pdf.pageIndex, 1)
    }
}
