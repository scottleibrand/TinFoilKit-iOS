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

    func testResourceInventoryIsOmittedByDefault() throws {
        let snapshot = HouseholdSnapshot(resources: [
            HouseholdResource(name: "Porch water jug", category: .water, quantity: 12, quantityUnit: .gallons,
                              dailyUse: 3, dailyUseUnit: .gallons)
        ])
        let data = try HouseholdPrinting.householdPDF(for: snapshot, regions: [])
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(pdf.string)
        XCTAssertEqual(pdf.pageCount, 1)
        XCTAssertFalse(text.contains("Resource inventory"))
        XCTAssertFalse(text.contains("Porch water jug"))
    }

    func testOptInPrintsResourceEstimatesAndMissingData() throws {
        let snapshot = HouseholdSnapshot(resources: [
            HouseholdResource(name: "Porch water jug", category: .water, quantity: 12, quantityUnit: .gallons,
                              dailyUse: 3, dailyUseUnit: .gallons),
            HouseholdResource(name: "Supper bin", category: .food, quantity: 5, quantityUnit: .meals,
                              dailyUse: 2, dailyUseUnit: .meals),
            HouseholdResource(name: "Travel medication", category: .medication, quantity: nil, quantityUnit: .doses,
                              dailyUse: nil, dailyUseUnit: .doses)
        ])
        let data = try HouseholdPrinting.householdPDF(for: snapshot, regions: [], includeResourceRunway: true)
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        let text = try XCTUnwrap(pdf.string)
        XCTAssertTrue(text.contains("Resource inventory"))
        XCTAssertTrue(text.contains("Shortest estimate · Supper bin · \(HouseholdResource.formatDays(2.5))"))
        XCTAssertTrue(text.contains("Porch water jug · Water"))
        XCTAssertTrue(text.contains("\(12.formatted()) US gallons"))
        XCTAssertTrue(text.contains("\(3.formatted()) US gallons per day"))
        XCTAssertTrue(text.contains("Estimated \(HouseholdResource.formatDays(4)) remaining"))
        XCTAssertTrue(text.contains("Travel medication"))
        XCTAssertTrue(text.contains("Quantity not recorded"))
        XCTAssertTrue(text.contains("Daily use not recorded"))
        XCTAssertTrue(text.contains("Runway estimate unavailable"))
    }
}
