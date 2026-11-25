import Foundation
import XCTest
@testable import TinfoilKit

final class AskEvidenceTests: XCTestCase {
    func testSavedAnswerAndCitationExcerptDoNotBecomeReferencePassages() {
        let citationOnly = source("citation-only", text: nil)
        let answer = savedAnswer([citationOnly])
        XCTAssertTrue(AskEvidence.combine([], savedAnswers: [answer], savedWebSources: [],
                                         question: "Where are the batteries?").isEmpty)
    }

    func testSavedSourceTextRemainsCitableAndIsDeduplicated() {
        let directCopy = source("home-checklist", text: "Batteries are in the west cabinet.")
        let retainedCopy = source("emergency-guide", text: "Store batteries in a cool dry place.")
        let answer = savedAnswer([directCopy, retainedCopy])
        let evidence = AskEvidence.combine([], savedAnswers: [answer], savedWebSources: [directCopy],
                                           question: "Where are the batteries?")
        XCTAssertEqual(evidence.map(\.excerpt), [
            "Batteries are in the west cabinet.", "Store batteries in a cool dry place."
        ])
        XCTAssertEqual(Set(evidence.map(\.id)).count, 2)
    }

    func testUnrelatedSavedWebTextDoesNotSuppressLibrarySearch() {
        let weather = source("forecast", text: "Tomorrow will be overcast and cool.")
        XCTAssertTrue(AskEvidence.combine([], savedAnswers: [], savedWebSources: [weather],
                                         question: "Where are the batteries?").isEmpty)
    }

    private func source(_ path: String, text: String?) -> OnlineAskSavedSource {
        OnlineAskSavedSource(citation: .init(
            url: URL(string: "https://example.invalid/\(path)")!,
            title: path, excerpt: "Provider snippet says to look in the attic."
        ), resolvedURL: nil, text: text, note: nil)
    }

    private func savedAnswer(_ sources: [OnlineAskSavedSource]) -> OnlineAskSavedAnswer {
        OnlineAskSavedAnswer(provider: .gpt, question: "Where are the batteries?",
                             answer: "The generated answer says to look in the attic.", sources: sources)
    }
}
