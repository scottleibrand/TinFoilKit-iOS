import XCTest
@testable import TinfoilKit

final class AnswerCitationBoundaryTests: XCTestCase {
    func testStreamingHoldsBackTextAfterLastCitation() {
        XCTAssertEqual(AnswerCitations.completedPrefix(in: "The note names the west cabinet [1]. A new claim",
                                                      sourceCount: 2), "The note names the west cabinet [1].")
        XCTAssertEqual(AnswerCitations.completedPrefix(in: "The note names the west cabinet [1].\nStill writing",
                                                      sourceCount: 2), "The note names the west cabinet [1].")
        XCTAssertNil(AnswerCitations.completedPrefix(in: "Uncited opening.\nThe note names the west cabinet [1].",
                                                    sourceCount: 2))
    }

    func testFinalAnswerRequiresEachNonemptyLineToEndWithSources() {
        XCTAssertTrue(AnswerCitations.isComplete("The note names the west cabinet [1].\n\nCheck both references [1] [2].",
                                                 sourceCount: 2))
        XCTAssertFalse(AnswerCitations.isComplete("The note names the west cabinet [1]. An uncited ending.",
                                                  sourceCount: 2))
        XCTAssertFalse(AnswerCitations.isComplete("The note names the west cabinet [1].\nNo evidence provided.",
                                                  sourceCount: 2))
        XCTAssertFalse(AnswerCitations.isComplete("[1] [2]", sourceCount: 2))
    }

    func testOutOfRangeAndMalformedCitationsFail() {
        for answer in ["A claim [0].", "A claim [1] [3].", "A claim [1,2].", "A claim [999999999999999999999]."] {
            XCTAssertFalse(AnswerCitations.isComplete(answer, sourceCount: 2), answer)
            XCTAssertNil(AnswerCitations.completedPrefix(in: answer, sourceCount: 2), answer)
        }
        XCTAssertEqual(AnswerCitations.indices(in: "A claim [2] [1] [2].", sourceCount: 2), [0, 1])
    }
}
