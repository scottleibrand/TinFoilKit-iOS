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
}
