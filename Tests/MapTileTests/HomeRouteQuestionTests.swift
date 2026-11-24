import XCTest
@testable import TinfoilKit

final class HomeRouteQuestionTests: XCTestCase {
    func testResolvesExplicitModeAndWholePinName() throws {
        let walk = try XCTUnwrap(HomeRouteQuestion.parse("Walk from HOME to Meeting Place?"))
        XCTAssertEqual(walk.mode, .walking)
        XCTAssertEqual(walk.matchingPins(in: ["Meeting", "Meeting Place North", "Meeting Place"]), [2])

        let drive = try XCTUnwrap(HomeRouteQuestion.parse("  DRIVE from home to Café  Azul. "))
        XCTAssertEqual(drive.mode, .driving)
        XCTAssertEqual(drive.matchingPins(in: ["Cafe Azul", "CAFÉ AZUL"]), [0, 1])
        XCTAssertTrue(drive.matchingPins(in: ["Azul"]).isEmpty)
    }

    func testStreetAddressRequiresAnExactStreetAndAnySpecifiedLocality() throws {
        let question = try XCTUnwrap(HomeRouteQuestion.parse("Drive from Home to 325 9th Avenue, Seattle."))
        XCTAssertTrue(question.isStreetAddress)
        XCTAssertTrue(question.matchesAddress("325 9th Avenue, Seattle, 98104"))
        XCTAssertFalse(question.matchesAddress("325 9th Avenue"))
        XCTAssertFalse(question.matchesAddress("325 9th Avenue, Bellevue"))
        XCTAssertFalse(question.matchesAddress("325 9th Avenue North, Seattle"))
        XCTAssertFalse(question.matchesAddress("3250 9th Avenue, Seattle"))
        XCTAssertFalse(try XCTUnwrap(HomeRouteQuestion.parse("Walk from Home to Meeting Place")).isStreetAddress)
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
            XCTAssertNil(HomeRouteQuestion.parse(question), question)
        }
    }
}
