import XCTest
@testable import TinfoilKit

final class SavedPinRouteQuestionTests: XCTestCase {
    func testResolvesExplicitModeAndWholePinName() throws {
        let walk = try XCTUnwrap(SavedPinRouteQuestion.parse("Walk from HOME to Meeting Place?"))
        XCTAssertEqual(walk.mode, .walking)
        XCTAssertEqual(walk.matchingPins(in: ["Meeting", "Meeting Place North", "Meeting Place"]), [2])

        let drive = try XCTUnwrap(SavedPinRouteQuestion.parse("  DRIVE from home to Café  Azul. "))
        XCTAssertEqual(drive.mode, .driving)
        XCTAssertEqual(drive.matchingPins(in: ["Cafe Azul", "CAFÉ AZUL"]), [0, 1])
        XCTAssertTrue(drive.matchingPins(in: ["Azul"]).isEmpty)
    }

    func testLeavesUnspecifiedModesAndOriginsWithOrdinaryAsk() {
        for question in [
            "Directions to Meeting Place",
            "Walk to Meeting Place",
            "Drive from work to Meeting Place",
            "How do I repair a walking stick?",
            "Walk from home to",
            "Walk from home to Meeting Place? Is it open?",
            String(repeating: "a", count: 513)
        ] {
            XCTAssertNil(SavedPinRouteQuestion.parse(question), question)
        }
    }
}
