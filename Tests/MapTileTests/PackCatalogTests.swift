import Foundation
import XCTest
@testable import TinfoilKit

final class PackCatalogTests: XCTestCase {
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
