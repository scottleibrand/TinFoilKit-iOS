import XCTest
@testable import TinfoilKit

final class NearbyServiceQuestionTests: XCTestCase {
    func testNearestServiceWithImplicitOrExplicitHomeOrigin() {
        XCTAssertEqual(NearbyServiceQuestion.parse("Where is the nearest pharmacy?"), .pharmacy)
        XCTAssertEqual(NearbyServiceQuestion.parse("  What’s the CLOSEST urgent  care clinic?\n"), .urgentCare)
        XCTAssertEqual(NearbyServiceQuestion.parse("Show me the nearest gas stations to my saved home."), .gas)
        XCTAssertEqual(NearbyServiceQuestion.parse("Where can I find a grocery store near home?"), .grocery)
        XCTAssertEqual(NearbyServiceQuestion.parse("drinking water sources around our home"), .drinkingWater)
    }

    func testOtherLocationsOrAdditionalRequirementsGoToOrdinaryAsk() {
        for question in [
            "What's the nearest pharmacy near me?",
            "Where are the closest pharmacies in Olympia?",
            "What's the nearest pharmacy to my office?",
            "Where is the nearest grocery store with a generator?",
            "Which pharmacy is open near home?",
            "How do I drive to the nearest hospital?",
            "Where is the nearest pharmacy or urgent care clinic?",
            "Is the nearest drinking water source safe after a flood?",
            "Where is the nearest pharmacy? I am on vacation.",
            "What is a hospital?",
            "Pharmacy"
        ] {
            XCTAssertNil(NearbyServiceQuestion.parse(question), question)
        }
    }

    func testExplicitDirectionsMatchOnlyNearbyServicesFromHome() {
        XCTAssertEqual(NearbyServiceQuestion.parseDirections("How do I get to the nearest hospital?"), .hospital)
        XCTAssertEqual(NearbyServiceQuestion.parseDirections(" DIRECTIONS from home to the closest pharmacy. "), .pharmacy)
        XCTAssertEqual(NearbyServiceQuestion.parseDirections("Directions to nearest gas station"), .gas)
        for question in [
            "Directions to the nearest hospital near me",
            "Directions to the nearest hospital with an emergency room",
            "Directions from work to the nearest hospital",
            "Directions from home to 350 Fifth Avenue",
            "Directions to a pharmacy",
            "Where is the closest pharmacy?"
        ] {
            XCTAssertNil(NearbyServiceQuestion.parseDirections(question), question)
        }
    }

    func testNearbyServiceCategoriesMatchPlaceIndex() {
        XCTAssertEqual(Set(NearbyServiceQuestion.allCases.map(\.rawValue)),
                       Set(RegionalPlaceIndex.Category.allCases.map(\.rawValue)))
    }
}
