import Foundation
import XCTest
@testable import TinfoilKit

final class DesktopHouseholdFilesTests: XCTestCase {
    func testImportKeepsOmittedFilesAndPlacesKeys() throws {
        let home = HouseholdPlace(name: "Existing home", latitude: 47.5, longitude: -122.2)
        let pin = HouseholdPlace(name: "Existing pin", latitude: 47.6, longitude: -122.3)
        let snapshot = HouseholdSnapshot(notes: "Existing notes", home: home, pins: [pin])
        let notes = Data([0xef, 0xbb, 0xbf]) + Data("Meeting point\r\nCall first".utf8)
        let updated = try DesktopHouseholdFiles.applying(notes: notes, to: snapshot)
        XCTAssertEqual(updated.notes, "Meeting point\r\nCall first")
        XCTAssertEqual(updated.home, home)
        XCTAssertEqual(updated.pins, [pin])

        let homeOnly = Data(#"{"home":null,"unrelated":1}"#.utf8)
        let withoutHome = try DesktopHouseholdFiles.applying(places: homeOnly, to: updated)
        XCTAssertNil(withoutHome.home)
        XCTAssertEqual(withoutHome.pins, [pin])
        XCTAssertEqual(withoutHome.notes, updated.notes)

        let cleared = try DesktopHouseholdFiles.applying(
            notes: Data(), places: Data(#"{"pins":[]}"#.utf8), to: withoutHome
        )
        XCTAssertEqual(cleared, HouseholdSnapshot())
    }

    func testDesktopAndNativePinIDsStayStable() throws {
        let native = UUID(uuidString: "eca36d86-ee9d-44bd-a86b-0cc26a6cd876")!
        let raw = Data("""
            {"home":{"lat":47.5,"lon":-122.2,"label":"","zoom":15},
             "pins":[{"id":"msp6mzkabcd","name":"Meeting point","note":"North door","lat":47.6,"lon":-122.3},
                     {"id":"\(native)","name":"Shelter","lat":47.7,"lon":-122.4}]}
            """.utf8)
        let first = try DesktopHouseholdFiles.applying(places: raw, to: HouseholdSnapshot(notes: "Keep"))
        XCTAssertEqual(first.home?.name, "Home")
        XCTAssertEqual(first.pins.last?.id, native)
        XCTAssertEqual(first.pins.first?.note, "North door")
        XCTAssertEqual(first, try DesktopHouseholdFiles.applying(places: raw, to: HouseholdSnapshot(notes: "Keep")))
        let reopened = try DesktopHouseholdFiles.applying(
            notes: DesktopHouseholdFiles.encodeNotes(first), places: DesktopHouseholdFiles.encodePlaces(first),
            to: HouseholdSnapshot()
        )
        XCTAssertEqual(reopened, first)
    }

    func testInvalidDataFailsInsteadOfDroppingHouseholdRecords() throws {
        let base = HouseholdSnapshot(notes: "Keep these notes")
        XCTAssertThrowsError(try DesktopHouseholdFiles.applying(notes: Data([0xff]), to: base))
        XCTAssertThrowsError(try DesktopHouseholdFiles.applying(places: Data(#"{"pins":null}"#.utf8), to: base))
        XCTAssertThrowsError(try DesktopHouseholdFiles.applying(
            places: Data(#"{"home":{"lat":91,"lon":12}}"#.utf8), to: base
        ))
        XCTAssertThrowsError(try DesktopHouseholdFiles.applying(
            places: Data(#"{"pins":[{"id":"same","name":"A","lat":0,"lon":0},{"id":"same","name":"B","lat":0,"lon":0}]}"#.utf8),
            to: base
        ))
    }
}
