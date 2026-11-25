import PDFKit
import XCTest
import ZIMArchive
@testable import TinfoilKit

final class HouseholdPrintingTests: XCTestCase {
    func testInstalledReadyGovEditionOpensAndPrintsThePowerOutageGuide() async throws {
        let edition = try XCTUnwrap(PackCatalog.entries.first { $0.pack.id == "ready-gov-en-all" }?.pack)
        let library = InstalledLibrary.standard
        guard let installed = try await library.archives().first(where: { $0.pack == edition }) else {
            throw XCTSkip("Install the pinned Ready.gov edition from Content Packs before this offline check.")
        }
        let file = await library.fileURL(for: installed.id)
        let archive = try ZIMArchive(fileURL: file)
        let main = try archive.mainArticle()
        XCTAssertEqual(main.path, "www.ready.gov/")
        XCTAssertTrue(main.mimeType.hasPrefix("text/html"))
        let home = try XCTUnwrap(ArchiveWebAddress.url(for: main.path))
        XCTAssertEqual(try archive.resource(at: XCTUnwrap(ArchiveWebAddress.path(in: home))).path, main.path)

        for link in ["power-outages", "earthquakes", "be-informed"] {
            let url = try XCTUnwrap(URL(string: link, relativeTo: home)?.absoluteURL)
            let resource = try archive.resource(at: XCTUnwrap(ArchiveWebAddress.path(in: url)))
            XCTAssertTrue(resource.mimeType.hasPrefix("text/html"), link)
            XCTAssertFalse(resource.data.isEmpty, link)
        }

        let references = try HouseholdPrinting.availableReferences(in: [
            .init(archive: edition.source.lastPathComponent, file: file, attribution: edition.attribution)
        ])
        let power = try XCTUnwrap(references.first { $0.id == "power" })
        let excerpt = try XCTUnwrap(PDFDocument(data: power.printablePDF()))
        XCTAssertEqual(excerpt.pageCount, 2)
        XCTAssertTrue(excerpt.string?.localizedCaseInsensitiveContains("power outage") == true)
    }

    func testBlankHouseholdSheetFitsOnePageWithFillInPrompts() throws {
        let data = try HouseholdPrinting.householdPDF(for: HouseholdSnapshot(), regions: [])
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertTrue(pdf.string?.contains("Allergies and medications") == true)
        XCTAssertTrue(pdf.string?.contains("Out-of-area contact") == true)
    }

    func testLongNotesContinueOnAdditionalPagesWithHomeAndPinDetails() throws {
        let snapshot = HouseholdSnapshot(
            notes: String(repeating: "Check the supplies.\n", count: 150) + "Last line of notes",
            home: HouseholdPlace(name: "Riverview Home", latitude: 47.6, longitude: -122.3),
            pins: [HouseholdPlace(name: "Meeting point", note: "North entrance", latitude: 47.61, longitude: -122.31)]
        )
        let data = try HouseholdPrinting.householdPDF(for: snapshot, regions: [])
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Riverview Home") == true)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("North entrance") == true)
        XCTAssertTrue(pdf.page(at: pdf.pageCount - 1)?.string?.contains("Last line of notes") == true)
    }
}
