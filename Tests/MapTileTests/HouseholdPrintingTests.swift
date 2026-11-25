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

    func testPinnedWaterAndMedicineEditionsPrintExpectedPageCounts() throws {
        let root = URL.documentsDirectory.appendingPathComponent("Print Editions")
        let archives = ["zimgit-water_en_2024-08.zim", "zimgit-medicine_en_2024-08.zim"]
        let installed = archives.map {
            HouseholdPrinting.InstalledSource(archive: $0, file: root.appendingPathComponent($0),
                                             attribution: "Publisher edition fixture")
        }
        try XCTSkipUnless(installed.allSatisfy { FileManager.default.fileExists(atPath: $0.file.path) },
                          "Stage the pinned Water Treatment and Field Medicine archives in Documents/Print Editions.")
        let references = try HouseholdPrinting.availableReferences(in: installed)
        for (id, pages) in [("water", 2), ("first-aid", 6), ("injuries", 5), ("bleeding", 5)] {
            let reference = try XCTUnwrap(references.first { $0.id == id }, id)
            let pdf = try XCTUnwrap(PDFDocument(data: reference.printablePDF()), id)
            XCTAssertEqual(pdf.pageCount, pages, id)
            XCTAssertFalse(pdf.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true, id)
        }
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
