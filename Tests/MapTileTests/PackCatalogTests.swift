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
}
