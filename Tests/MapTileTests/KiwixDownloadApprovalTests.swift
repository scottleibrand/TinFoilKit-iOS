import Foundation
import XCTest
@testable import TinfoilKit
import ZIMArchive

final class KiwixDownloadApprovalTests: XCTestCase {
    func testRestoresApprovedEditionAndNetworkChoice() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pack = try XCTUnwrap(KiwixDownloadApproval.pack(for: book(), metadata: metadata()))
        XCTAssertEqual(pack.version, "2026-10")
        XCTAssertEqual(pack.sizeEstimate, 42)
        XCTAssertEqual(pack.attribution, "Wikipedia · archive distributed by Kiwix")
        XCTAssertTrue(KiwixDownloadApproval.load(from: directory).isEmpty)
        let approved = KiwixDownloadApproval(pack: pack, allowsCellular: true)
        try approved.save(in: directory)
        XCTAssertEqual(KiwixDownloadApproval.load(from: directory), [pack.editionKey: approved])
        let wifi = KiwixDownloadApproval(pack: pack, allowsCellular: false)
        try wifi.save(in: directory)
        XCTAssertEqual(KiwixDownloadApproval.load(from: directory), [pack.editionKey: wifi])
        try wifi.remove(from: directory)
        XCTAssertTrue(KiwixDownloadApproval.load(from: directory).isEmpty)
    }

    func testRejectsUnmatchedFileAndUntrustedSource() {
        XCTAssertNil(KiwixDownloadApproval.pack(for: book(), metadata: metadata(filename: "other.zim")))
        XCTAssertNil(KiwixDownloadApproval.pack(for: book(host: "example.org"), metadata: metadata()))
        XCTAssertNil(KiwixDownloadApproval.pack(for: book(), metadata: metadata(size: .max)))
    }

    func testIgnoresMismatchedReceiptFilenameAndInvalidStoredMetadata() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let pack = try XCTUnwrap(KiwixDownloadApproval.pack(for: book(), metadata: metadata()))
        let approved = KiwixDownloadApproval(pack: pack, allowsCellular: false)
        try JSONEncoder().encode(approved).write(to: directory.appendingPathComponent("wrong.publisher-approval"))
        let correctPath = directory.appendingPathComponent("\(pack.editionKey).publisher-approval")
        try Data("{}".utf8).write(to: correctPath)
        XCTAssertTrue(KiwixDownloadApproval.load(from: directory).isEmpty)
    }

    private func book(host: String = "download.kiwix.org") -> KiwixCatalog.Book {
        .init(id: UUID(), title: "Climate change", summary: "", language: "eng", updated: "", creator: "Wikipedia",
              estimatedBytes: 50, metalinkURL: URL(string: "https://\(host)/zim/wikipedia/climate_2026-10.zim.meta4")!,
              readerURL: nil)
    }

    private func metadata(filename: String = "climate_2026-10.zim", size: Int64 = 42) -> KiwixMetalink {
        .init(filename: filename, byteCount: size, sha256: String(repeating: "a", count: 64))
    }
}
