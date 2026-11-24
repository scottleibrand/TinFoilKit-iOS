import Foundation
import XCTest
@testable import TinfoilKit

final class PackCatalogTests: XCTestCase {
    func testCompleteEnglishWikipediaIsCurrentAndIndividualOnly() throws {
        let catalog = try XCTUnwrap(Bundle.main.url(forResource: "PackCatalog", withExtension: "json"))
        let entries = try PackCatalog.load(from: catalog)
        let complete = try XCTUnwrap(entries.first { $0.pack.id == "wikipedia-en-all-maxi" })
        XCTAssertEqual(complete.pack.sizeEstimate, 127_418_087_648)
        XCTAssertTrue(complete.isDefault)
        XCTAssertFalse(complete.isBulkEligible)
        XCTAssertFalse(complete.allowsArchiveSharing)

        let highlights = try XCTUnwrap(entries.first { $0.pack.id == "wikipedia-en-top-nopic" })
        XCTAssertTrue(highlights.isBulkEligible)
        XCTAssertTrue(entries.filter { !$0.isDefault }.allSatisfy { !$0.isBulkEligible })
    }

    func testWikiMedIsCurrentAndIndividualOnly() throws {
        let catalog = try XCTUnwrap(Bundle.main.url(forResource: "PackCatalog", withExtension: "json"))
        let entries = try PackCatalog.load(from: catalog)
        let wikiMed = try XCTUnwrap(entries.first { $0.pack.id == "mdwiki-en-all-maxi" })
        XCTAssertEqual(wikiMed.pack.sizeEstimate, 2_302_838_768)
        XCTAssertEqual(wikiMed.section, .extended)
        XCTAssertEqual(wikiMed.language, .english)
        XCTAssertTrue(wikiMed.isDefault)
        XCTAssertFalse(wikiMed.isBulkEligible)
        XCTAssertFalse(wikiMed.usesPDFDirectory)
        XCTAssertFalse(wikiMed.allowsArchiveSharing)
    }
}
