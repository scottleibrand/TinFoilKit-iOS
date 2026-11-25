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

    func testReplacementRetainsSeriesIdentityAndPersistsExactTarget() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let baseline = try XCTUnwrap(PackCatalog.entries.first { $0.pack.id == "wikipedia-en-simple-mini" }?.pack)
        let filename = "wikipedia_en-simple_all_mini_2099-01.zim"
        let item = KiwixCatalog.Book(
            id: UUID(), title: "Simple English Wikipedia", summary: "", language: "eng", updated: "",
            creator: "Wikipedia", estimatedBytes: 50,
            metalinkURL: try XCTUnwrap(URL(string: "https://download.kiwix.org/zim/wikipedia/\(filename).meta4")),
            readerURL: nil
        )
        let candidate = try XCTUnwrap(KiwixDownloadApproval.pack(for: item, metadata: metadata(filename: filename)))
        let replacement = try XCTUnwrap(KiwixDownloadApproval.replacement(for: candidate, in: baseline))
        XCTAssertEqual(replacement.id, baseline.id)
        XCTAssertEqual(replacement.version, "2099-01")
        XCTAssertEqual(replacement.sha256, candidate.sha256)
        XCTAssertFalse(KiwixDownloadApproval.isValid(replacement))
        let unrelated = try XCTUnwrap(KiwixDownloadApproval.pack(for: book(), metadata: metadata()))
        XCTAssertNil(KiwixDownloadApproval.replacement(for: unrelated, in: baseline))
        let unbound = KiwixDownloadApproval(pack: replacement, allowsCellular: true)
        XCTAssertThrowsError(try unbound.save(in: directory))
        let approved = KiwixDownloadApproval(pack: replacement, allowsCellular: true, replacesArchiveID: UUID())
        try approved.save(in: directory)
        XCTAssertEqual(KiwixDownloadApproval.load(from: directory), [replacement.editionKey: approved])
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
