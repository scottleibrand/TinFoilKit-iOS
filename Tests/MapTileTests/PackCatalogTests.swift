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

    func testDesktopStarterEditionsArePinnedAndEligibleForEssentials() throws {
        let catalog = try XCTUnwrap(Bundle.main.url(forResource: "PackCatalog", withExtension: "json"))
        let entries = try PackCatalog.load(from: catalog)
        let editions: [String: (version: String, bytes: Int64)] = [
            "zimgit-post-disaster-en": ("2024-05", 644_665_513),
            "zimgit-food-preparation-en": ("2025-04", 97_822_565),
            "zimgit-knots-en": ("2024-08", 27_945_133),
            "fas-military-medicine-en": ("2026-10", 64_986_090)
        ]
        for (id, edition) in editions {
            let entry = try XCTUnwrap(entries.first { $0.pack.id == id })
            XCTAssertEqual(entry.pack.version, edition.version)
            XCTAssertEqual(entry.pack.sizeEstimate, edition.bytes)
            XCTAssertEqual(entry.section, .essentials)
            XCTAssertEqual(entry.language, .english)
            XCTAssertTrue(entry.isBulkEligible)
            XCTAssertTrue(entry.usesPDFDirectory)
            XCTAssertFalse(entry.allowsArchiveSharing)
        }

        let climate = try XCTUnwrap(entries.first { $0.pack.id == "wikipedia-en-climate-change" })
        XCTAssertEqual(climate.pack.sizeEstimate, 12_143_778)
    }
}
