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

    func testNeutralDirectionsAndProceduralFallback() throws {
        let address = try XCTUnwrap(HomeRouteQuestion.parse("Directions from Home to 350 Fifth Avenue, New York"))
        XCTAssertEqual(address.mode, .choose)
        XCTAssertEqual(address.rawDestination, "350 Fifth Avenue, New York")
        XCTAssertTrue(address.matchesAddress("350 Fifth Avenue, New York, 10118"))
        XCTAssertFalse(address.allowsLibraryFallback)

        let pin = try XCTUnwrap(HomeRouteQuestion.parse("Directions to the meeting place"))
        XCTAssertEqual(pin.mode, .choose)
        XCTAssertEqual(pin.destination, "the meeting place")
        XCTAssertEqual(pin.matchingPins(in: ["Meeting Place"]), [0])
        XCTAssertEqual(pin.matchingPins(in: ["Meeting Place", "The Meeting Place"]), [1])
        XCTAssertFalse(pin.allowsLibraryFallback)

        let ambiguous = try XCTUnwrap(HomeRouteQuestion.parse("How do I get to the backup entrance?"))
        XCTAssertEqual(ambiguous.mode, .choose)
        XCTAssertTrue(ambiguous.allowsLibraryFallback)

        XCTAssertEqual(HomeRouteQuestion.parse("How do I walk from Home to the library?")?.mode, .walking)
        let drive = try XCTUnwrap(HomeRouteQuestion.parse("How do I drive from Home to the library?"))
        XCTAssertEqual(drive.mode, .driving)
        XCTAssertFalse(drive.allowsLibraryFallback)
    }

    func testPreservesCoordinatePunctuationAndExactNamedMatches() throws {
        let decimal = try XCTUnwrap(HomeRouteQuestion.parse("Directions to .5, -122.3321?"))
        XCTAssertEqual(decimal.rawDestination, ".5, -122.3321")
        let degrees = try XCTUnwrap(HomeRouteQuestion.parse("Directions to 47°36′22″N, 122°19′55″W."))
        XCTAssertEqual(degrees.rawDestination, "47°36′22″N, 122°19′55″W")

        let named = try XCTUnwrap(HomeRouteQuestion.parse("Directions to Café  Azul"))
        XCTAssertTrue(named.matchesName("Cafe Azul"))
        XCTAssertFalse(named.matchesName("Café Azul South"))
        XCTAssertFalse(named.matchesName("My Café Azul"))
        XCTAssertNotNil(HomeRouteQuestion.parse("Directions to St. James Cathedral"))
    }

    func testPinAliasPrefersAnyExactMatch() throws {
        let personal = try XCTUnwrap(HomeRouteQuestion.parse("Directions to my meeting place"))
        XCTAssertEqual(personal.matchingPins(in: ["Meeting Place", "My Meeting Place", "MY MEETING PLACE"]), [1, 2])
        XCTAssertEqual(personal.matchingPins(in: ["Meeting Place", "Meeting Place North"]), [0])
        XCTAssertFalse(personal.matchesName("Meeting Place"))
        XCTAssertTrue(personal.matchesName("My Meeting Place"))
        let shared = try XCTUnwrap(HomeRouteQuestion.parse("Directions to our meeting place"))
        XCTAssertEqual(shared.matchingPins(in: ["Meeting Place", "Meeting Place North"]), [0])
    }

    func testLeavesUnsupportedOriginsAndCompoundQuestionsWithOrdinaryAsk() {
        for question in [
            "Walk to Meeting Place",
            "Drive from work to Meeting Place",
            "How do I repair a walking stick?",
            "Walk from home to",
            "Walk from home to Meeting Place? Is it open?",
            "Directions from work to Meeting Place",
            "Directions to Meeting Place; is it open?",
            "Directions to Meeting Place. Where do I park?",
            "Directions to Meeting Place, and tell me if it's open",
            "Directions to ?!",
            String(repeating: "a", count: 513)
        ] {
            XCTAssertNil(HomeRouteQuestion.parse(question), question)
        }
    }
}
