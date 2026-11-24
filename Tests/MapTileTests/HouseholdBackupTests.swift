import Foundation
import XCTest
@testable import TinfoilKit

final class HouseholdBackupTests: XCTestCase {
    func testNativeBackupRoundTripsAndReplacesHousehold() throws {
        let snapshot = HouseholdSnapshot(
            notes: "Call first",
            home: HouseholdPlace(name: "Home", latitude: 47.5, longitude: -122.2),
            pins: [HouseholdPlace(name: "Meeting point", note: "North door", latitude: 47.6, longitude: -122.3)]
        )
        let encoded = try HouseholdBackup.encode(snapshot)
        XCTAssertEqual(
            try HouseholdBackup.importing(encoded, as: .native, into: HouseholdSnapshot(notes: "Other")),
            snapshot
        )
        XCTAssertThrowsError(try HouseholdBackup.importing(encoded, as: .desktopPlaces, into: snapshot))
        XCTAssertEqual(try HouseholdBackup.importing(encoded, asText: false, into: HouseholdSnapshot()), snapshot)

        let newerVersion = try XCTUnwrap(String(data: encoded, encoding: .utf8))
            .replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2")
        XCTAssertThrowsError(try HouseholdBackup.importing(Data(newerVersion.utf8), as: .native, into: snapshot))
    }

    func testDesktopPlacesRejectUnrelatedJSON() throws {
        let snapshot = HouseholdSnapshot(notes: "Keep this")
        for json in ["{}", #"{"storage":42}"#, "[]"] {
            XCTAssertThrowsError(try HouseholdBackup.importing(Data(json.utf8), as: .desktopPlaces, into: snapshot))
        }
        let updated = try HouseholdBackup.importing(Data(#"{"home":null}"#.utf8), as: .desktopPlaces, into: snapshot)
        XCTAssertEqual(updated.notes, snapshot.notes)
        XCTAssertEqual(try HouseholdBackup.importing(Data("New".utf8), asText: true, into: snapshot).notes, "New")
        for json in [#"{"format":null,"pins":[]}"#, #"{"format":"foreign","home":null}"#] {
            XCTAssertThrowsError(try HouseholdBackup.importing(Data(json.utf8), asText: false, into: snapshot))
        }
    }

    @MainActor
    func testRestoreKeepsUnreadableOriginalAndResetsLoadingError() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("household.json")
        let original = Data("unreadable".utf8)
        try original.write(to: file)
        let store = HouseholdStore(file: file)
        XCTAssertNotNil(store.loadError)

        let invalid = HouseholdPlace(name: "Invalid", latitude: 100, longitude: 0)
        XCTAssertThrowsError(try store.restore(HouseholdSnapshot(home: invalid)))
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), [file.lastPathComponent])

        let next = HouseholdSnapshot(notes: "Restored")
        try store.restore(next)
        XCTAssertNil(store.loadError)
        XCTAssertEqual(store.snapshot, next)
        XCTAssertEqual(HouseholdStore(file: file).snapshot, next)
        let recoveries = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            .filter { $0.hasPrefix("household-unreadable-") }
        XCTAssertEqual(recoveries.count, 1)
        let recovery = folder.appendingPathComponent(try XCTUnwrap(recoveries.first))
        XCTAssertEqual(try Data(contentsOf: recovery), original)
    }
}
