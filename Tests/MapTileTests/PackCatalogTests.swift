import CryptoKit
import Foundation
import ZIMArchive
import XCTest
@testable import TinfoilKit

final class PackCatalogTests: XCTestCase {
    @MainActor
    func testOnlyThePinnedMITStarterIsApprovedForNearbyAndStandardShipsItsExactBytes() async throws {
        let entry = try XCTUnwrap(PackCatalog.entries.first { $0.allowsArchiveSharing })
        XCTAssertEqual(PackCatalog.entries.filter(\.allowsArchiveSharing).map(\.pack.id), ["tinfoil-kit-offline-starter"])
        XCTAssertFalse(entry.isBulkEligible)
        let catalog = NearbyArchiveCatalog(downloads: .shared)
        let pin = try XCTUnwrap(catalog.pins.first)
        XCTAssertEqual(catalog.pins.count, 1)
        XCTAssertEqual(pin.sha256, entry.pack.sha256)

        if Bundle.main.object(forInfoDictionaryKey: "TFKLightweightProfile") as? Bool == true {
            XCTAssertNil(PackCatalog.bundledCopy(for: entry.pack))
        } else {
            let file = try XCTUnwrap(PackCatalog.bundledCopy(for: entry.pack))
            let offered = await catalog.source(pin)
            XCTAssertEqual(offered, file)
            let bytes = try Data(contentsOf: file)
            XCTAssertEqual(Int64(bytes.count), entry.pack.sizeEstimate)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(digest, entry.pack.sha256)
            let archive = try ZIMArchive(fileURL: file)
            XCTAssertEqual(archive.title, entry.pack.title)
            XCTAssertTrue(String(decoding: try archive.resource(at: "license.html").data, as: UTF8.self)
                .contains("MIT License"))
        }
    }

    @MainActor
    func testHouseholdSharesOnlySelectedMITStarterChaptersWithLicense() async throws {
        guard Bundle.main.object(forInfoDictionaryKey: "TFKLightweightProfile") as? Bool != true else {
            throw XCTSkip("The standard profile bundles the starter edition.")
        }
        let chapters = await HouseholdShareView.starterReferences()
        XCTAssertEqual(chapters.map(\.id), ["offline-starter-earthquake-safety", "offline-starter-prepare-offline"])
        XCTAssertTrue(chapters.allSatisfy { $0.text.contains("MIT License") })
        let selected = try XCTUnwrap(chapters.first)
        let page = HouseholdSharePage(snapshot: HouseholdSnapshot(), publicReferences: [selected])
        let html = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(html.contains(selected.title))
        XCTAssertFalse(html.contains("offline-starter-prepare-offline"))
    }

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
