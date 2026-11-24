import XCTest
import ZIMArchive
@testable import TinfoilKit

final class LibraryPassagesTests: XCTestCase {
    private let outageQuestion = "How long does our water system keep working if there is a gridwide power outage?"

    func testUtilityOutageQueriesKeepBothConcepts() {
        let queries = LibraryPassages.queries(for: outageQuestion, suggested: [])
        XCTAssertTrue(queries.contains("water power outage"))
        XCTAssertTrue(queries.contains("water backup power"))
        XCTAssertFalse(queries.contains("water"))
        XCTAssertFalse(queries.contains("outage"))
        XCTAssertTrue(LibraryPassages.SearchIntent("If the whole area loses power, how long does water keep working?").isWaterServiceOutage)
    }

    func testUtilityOutageSearchRequiresRelevantContext() throws {
        let intent = LibraryPassages.SearchIntent(outageQuestion)
        XCTAssertNil(intent.score(match("European power outage", "The electrical grid suffered a power outage."), rank: 0, queryOrder: 0))
        XCTAssertNil(intent.score(match("Deep Lake Water Cooling System", "Toronto uses deep lake water to cool buildings."), rank: 0, queryOrder: 0))
        XCTAssertNil(intent.score(match("Power outage", "Residents filled containers with water before the storm."), rank: 0, queryOrder: 0))

        let direct = match("Preparedness guide", "During a power outage, check notices from your drinking water utility.")
        let titled = match("Water utility guide", "Check the backup power available at your facilities.")
        let directScore = try XCTUnwrap(intent.score(direct, rank: 1, queryOrder: 1))
        let titledScore = try XCTUnwrap(intent.score(titled, rank: 1, queryOrder: 1))
        XCTAssertGreaterThan(directScore, titledScore)
    }

    func testAnOutageQuestionWithoutServiceIntentKeepsOrdinarySearch() throws {
        let intent = LibraryPassages.SearchIntent("How much drinking water should I store for a blackout?")
        XCTAssertFalse(intent.isWaterServiceOutage)
        XCTAssertNotNil(intent.score(match("Emergency water storage", "Store drinking water in clean containers."), rank: 0, queryOrder: 0))
        let ordinary = LibraryPassages.queries(for: "What is anthropogenic climate change?", suggested: [])
        XCTAssertTrue(ordinary.contains("anthropogenic climate change"))
    }

    private func match(_ title: String, _ excerpt: String) -> ArticleIndex.Match {
        ArticleIndex.Match(path: title, title: title, excerpt: excerpt, rank: -1)
    }
}
