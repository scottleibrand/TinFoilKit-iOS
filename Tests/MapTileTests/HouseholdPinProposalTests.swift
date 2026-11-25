import Foundation
import XCTest
@testable import TinfoilKit

final class HouseholdPinProposalTests: XCTestCase {
    func testPinCarriesOnlyReviewedFieldsAndGetsItsOwnIdentity() throws {
        let form = Data("name=Corner+library&coordinates=47.6%2C+-122.3&note=Side+entrance".utf8)
        let first = try XCTUnwrap(HouseholdPinProposal.parse(form))
        let second = try XCTUnwrap(HouseholdPinProposal.parse(form))
        XCTAssertEqual(first.name, "Corner library")
        XCTAssertEqual(first.latitude, 47.6)
        XCTAssertEqual(first.longitude, -122.3)
        XCTAssertEqual(first.note, "Side entrance")
        XCTAssertNotEqual(first.id, second.id)
    }

    func testRejectsInvalidPlacesAndExtraFields() {
        for text in ["name=Corner&coordinates=91,0", "name=Corner&coordinates=47.6,-122.3&name=Other",
                     "name=Corner&coordinates=47.6,-122.3&id=42", "name=%00Corner&coordinates=47.6,-122.3",
                     "name=Corner&coordinates=47.6,-122.3&note=%FF", "name=Corner&coordinates=47.6,-122.3&home=true"] {
            XCTAssertNil(HouseholdPinProposal.parse(Data(text.utf8)), text)
        }
    }

    func testPinOnlySessionShowsPinFormWithoutPrivateDetails() {
        let page = HouseholdSharePage(snapshot: HouseholdSnapshot(), acceptsPins: true)
        let html = String(decoding: page.body, as: UTF8.self)
        XCTAssertTrue(html.contains("Suggest a map pin"))
        XCTAssertFalse(html.contains("Send a note to the host"))
        XCTAssertFalse(html.contains("<h2>Home</h2>"))
        XCTAssertTrue(page.contentSecurityPolicy.contains("connect-src 'self'"))
    }

    func testPinAndNotePermissionsAreIndependent() {
        typealias Kind = HouseholdGuestProposal.Kind
        let pinHeaders = [Kind.pin.marker: ["1"]]
        let noteHeaders = [Kind.note.marker: ["1"]]
        XCTAssertEqual(Kind.permitted(headers: pinHeaders, acceptsNotes: false, acceptsPins: true), .pin)
        XCTAssertNil(Kind.permitted(headers: pinHeaders, acceptsNotes: true, acceptsPins: false))
        XCTAssertEqual(Kind.permitted(headers: noteHeaders, acceptsNotes: true, acceptsPins: false), .note)
        XCTAssertNil(Kind.permitted(headers: noteHeaders, acceptsNotes: false, acceptsPins: true))
    }
}
