import PDFKit
import XCTest
@testable import TinfoilKit

final class HouseholdPrintingTests: XCTestCase {
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

    func testPrintReferenceVerifiesDocumentBytesBeforeSelectingPhysicalPages() throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pdf-collection", withExtension: "zim"))
        let title = "Water Guide"
        let path = "files/Water Guide.pdf"
        let source = HouseholdPrinting.Reference.Source(archive: "pdf-collection.zim", path: path,
            sha256: "7aa96cf2897ff10e690a6eb9f8e1f8806c15abd69ee8fa81bad67aae5eecdef5")
        let wrongDigest = HouseholdPrinting.Reference.Source(archive: source.archive, path: path,
            sha256: "601a4ed27f67d65c3b418a4f278dd0c36eb33d6aaaa34d25c1364292dfdc77fd")
        let reference = HouseholdPrinting.Reference(id: "water-fixture", title: title, document: title,
                                                     pages: 2...2, sources: [source])

        let requested = HouseholdPrinting.AvailableReference(reference: reference, file: file, source: source, attribution: "Fixture")
        let pdf = try XCTUnwrap(PDFDocument(data: try requested.printablePDF()))
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertTrue(pdf.page(at: 0)?.string?.contains("Ceramic filtration removes protozoa.") == true)

        XCTAssertThrowsError(try HouseholdPrinting.AvailableReference.openPDF(file: file, source: wrongDigest, pages: 2...2))
        XCTAssertThrowsError(try HouseholdPrinting.AvailableReference.openPDF(file: file, source: source, pages: 3...3))
    }
}
