import XCTest
@testable import TinfoilKit

final class AnswerCitationBoundaryTests: XCTestCase {
    func testStreamingHoldsBackTextAfterLastCitation() {
        XCTAssertEqual(AnswerCitations.completedPrefix(in: "The note names the west cabinet [1]. A new claim",
                                                      sourceCount: 2), "The note names the west cabinet [1].")
        XCTAssertEqual(AnswerCitations.completedPrefix(in: "The note names the west cabinet [1].\nStill writing",
                                                      sourceCount: 2), "The note names the west cabinet [1].")
        XCTAssertEqual(AnswerCitations.completedPrefix(in: "The note names the west cabinet [1]. Next claim [",
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

    func testRejectsMixedCitationSyntaxAndNoncanonicalSourceLinks() throws {
        for answer in ["A claim [1] [2,3].", "A claim [[1]].", "A claim [1] [note].", "A claim [01]."] {
            XCTAssertFalse(AnswerCitations.isComplete(answer, sourceCount: 3), answer)
            XCTAssertNil(AnswerCitations.completedPrefix(in: answer, sourceCount: 3), answer)
        }
        for address in ["tinfoil-source://article/1", "tinfoil-source://article/01", "tinfoil-source://article/x/1",
                        "tinfoil-source://article/1?x=2", "tinfoil-source://article/1#details"] {
            let url = try XCTUnwrap(URL(string: address))
            XCTAssertEqual(AnswerCitations.sourceIndex(from: url, sourceCount: 3),
                           address == "tinfoil-source://article/1" ? 0 : nil)
        }
    }
}
