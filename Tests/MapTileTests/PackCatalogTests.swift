import Foundation
import XCTest
@testable import TinfoilKit

final class PackCatalogTests: XCTestCase {
    func testReadyGovIsAnIndividualArchiveWithExactPublisherPin() throws {
        let catalog = try XCTUnwrap(Bundle.main.url(forResource: "PackCatalog", withExtension: "json"))
        let entries = try PackCatalog.load(from: catalog)
        let ready = try XCTUnwrap(entries.first { $0.pack.id == "ready-gov-en-all" })
        XCTAssertEqual(ready.pack.source.lastPathComponent, "ready.gov_en_all_2026-10.zim")
        XCTAssertEqual(ready.pack.sha256, "c88ce03db2a6dd855c1075d87abb6dceac678718e0dd3fa7912009469b9ca225")
        XCTAssertEqual(ready.pack.sizeEstimate, 2_063_895_408)
        XCTAssertEqual(ready.section, .extended)
        XCTAssertTrue(ready.isDefault)
        XCTAssertFalse(ready.isBulkEligible)
        XCTAssertFalse(ready.usesPDFDirectory)
        XCTAssertFalse(ready.allowsArchiveSharing)
    }

    func testCompleteEnglishWikipediaIsCurrentAndIndividualOnly() throws {
        let catalog = try XCTUnwrap(Bundle.main.url(forResource: "PackCatalog", withExtension: "json"))
        let entries = try PackCatalog.load(from: catalog)
        let completeEditions: [String: Int64] = [
            "wikipedia-en-all-maxi": 127_418_087_648,
            "wikipedia-en-all-nopic": 52_690_706_555
        ]
        for (id, size) in completeEditions {
            let edition = try XCTUnwrap(entries.first { $0.pack.id == id })
            XCTAssertEqual(edition.pack.sizeEstimate, size)
            XCTAssertTrue(edition.isDefault)
            XCTAssertFalse(edition.isBulkEligible)
            XCTAssertFalse(edition.allowsArchiveSharing)
        }

        let highlights = try XCTUnwrap(entries.first { $0.pack.id == "wikipedia-en-top-nopic" })
        XCTAssertTrue(highlights.isBulkEligible)
        XCTAssertTrue(entries.filter { !$0.isDefault }.allSatisfy { !$0.isBulkEligible })
    }
}
