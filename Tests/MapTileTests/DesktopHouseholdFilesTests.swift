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
        var edited = first
        edited.pins[0].name = "Meet at the north door"
        let backup = try HouseholdBackup.encode(edited)
        let restored = try HouseholdBackup.importing(backup, as: .native, into: HouseholdSnapshot())
        let desktopPlaces = try DesktopHouseholdFiles.encodePlaces(restored)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: desktopPlaces) as? [String: Any])
        let home = try XCTUnwrap(json["home"] as? [String: Any])
        let pins = try XCTUnwrap(json["pins"] as? [[String: Any]])
        XCTAssertEqual(home["zoom"] as? Double, 15)
        XCTAssertEqual(pins.compactMap { $0["id"] as? String }, ["msp6mzkabcd", native.uuidString])
        XCTAssertEqual(pins.first?["name"] as? String, "Meet at the north door")
        let reopened = try DesktopHouseholdFiles.applying(
            notes: DesktopHouseholdFiles.encodeNotes(restored), places: desktopPlaces,
            to: HouseholdSnapshot()
        )
        XCTAssertEqual(reopened, edited)
    }

    func testUpdatingDesktopHomeKeepsPhoneOnlyNoteAtTheSameLocation() throws {
        let home = HouseholdPlace(name: "Original", note: "Side entrance", latitude: 47.5, longitude: -122.2,
                                  desktopHomeZoom: 16)
        let pin = HouseholdPlace(name: "Meeting point", latitude: 47.6, longitude: -122.3)
        let snapshot = HouseholdSnapshot(notes: "Keep", home: home, pins: [pin])
        let same = Data(#"{"home":{"lat":47.5,"lon":-122.2,"label":"Renamed"}}"#.utf8)
        let refreshed = try DesktopHouseholdFiles.applying(places: same, to: snapshot)
        XCTAssertEqual(refreshed.home?.name, "Renamed")
        XCTAssertEqual(refreshed.home?.note, home.note)
        XCTAssertEqual(refreshed.home?.desktopHomeZoom, 16)
        XCTAssertEqual(refreshed.notes, snapshot.notes)
        XCTAssertEqual(refreshed.pins, snapshot.pins)

        let moved = Data(#"{"home":{"lat":47.6,"lon":-122.2,"label":"New Home","zoom":12}}"#.utf8)
        let relocated = try DesktopHouseholdFiles.applying(places: moved, to: refreshed)
        XCTAssertEqual(relocated.home?.note, "")
        XCTAssertNil(relocated.home?.desktopHomeZoom)
    }

    func testExportIgnoresDesktopPinIDThatBelongsToAnotherPin() throws {
        let original = Data(#"{"pins":[{"id":"desktop-pin","name":"Gate","lat":0,"lon":0}]}"#.utf8)
        var snapshot = try DesktopHouseholdFiles.applying(places: original, to: HouseholdSnapshot())
        let local = HouseholdPlace(name: "Local", latitude: 1, longitude: 1, desktopPinID: "desktop-pin")
        snapshot.pins.append(local)
        let encoded = try DesktopHouseholdFiles.encodePlaces(snapshot)
        let reloaded = try DesktopHouseholdFiles.applying(places: encoded, to: HouseholdSnapshot())
        XCTAssertEqual(reloaded.pins.map(\.id), snapshot.pins.map(\.id))
        XCTAssertEqual(reloaded.pins.first?.desktopPinID, "desktop-pin")
        XCTAssertNil(reloaded.pins.last?.desktopPinID)
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
