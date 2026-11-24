import Foundation
import XCTest
@testable import TinfoilKit

final class OnlineAskClientTests: XCTestCase {
    func testGPTKeepsInlineCitationsAndCompleteSources() throws {
        let payload = #"""
        {"status":"completed","output":[
          {"type":"web_search_call","action":{"sources":[{"url":"https://example.org/document"},{"url":"https://example.org/related"}]}},
          {"type":"message","content":[{"type":"output_text","text":"Café helps. Another line.","annotations":[
            {"type":"url_citation","start_index":0,"end_index":11,"url":"https://example.org/document","title":"Official document"}
          ]}]}
        ]}
        """#
        let result = try OnlineAskClient.decode(Data(payload.utf8), from: .gpt)
        XCTAssertEqual(result.answer, "Café helps. [1](<https://example.org/document>) Another line.")
        XCTAssertEqual(result.citations.map(\.url.absoluteString),
                       ["https://example.org/document", "https://example.org/related"])
        XCTAssertEqual(result.citations[0].title, "Official document")
        XCTAssertNil(result.citations[0].excerpt, "Annotation coordinates refer to the answer, not a source excerpt.")
        XCTAssertTrue(result.cacheAllowed)
    }

    func testClaudeKeepsCitedTextAndOmitsUncitedHits() throws {
        let payload = #"""
        {"stop_reason":"end_turn","content":[
          {"type":"web_search_tool_result","content":[{"type":"web_search_result","url":"https://example.org/irrelevant"}]},
          {"type":"text","text":"First statement.","citations":[
            {"type":"web_search_result_location","title":"Source","url":"https://example.org/source","cited_text":"First excerpt."}
          ]},
          {"type":"text","text":"Second statement.","citations":[
            {"type":"web_search_result_location","title":"Source","url":"https://example.org/source","cited_text":"Second excerpt."}
          ]}
        ]}
        """#
        let result = try OnlineAskClient.decode(Data(payload.utf8), from: .claude)
        XCTAssertEqual(result.citations.count, 1)
        XCTAssertEqual(result.citations[0].excerpt, "First excerpt.\n\nSecond excerpt.")
        XCTAssertTrue(result.answer.hasPrefix("First statement. [1](<https://example.org/source>)"))
        XCTAssertTrue(result.cacheAllowed)
    }

    func testGeminiGroundedResponseUsesUTF8OffsetsAndSessionOnly() throws {
        let payload = #"""
        {"candidates":[{"finishReason":"STOP","content":{"parts":[{"text":"Café. Next line."}]},"groundingMetadata":{
          "groundingChunks":[{"web":{"uri":"https://example.org/source","title":"Grounding source"}}],
          "groundingSupports":[{"segment":{"endIndex":6},"groundingChunkIndices":[0]}],
          "searchEntryPoint":{"renderedContent":"<div>Suggestion</div>"}
        }}]}
        """#
        let result = try OnlineAskClient.decode(Data(payload.utf8), from: .gemini)
        XCTAssertEqual(result.answer, "Café. [1](<https://example.org/source>) Next line.")
        XCTAssertEqual(result.searchEntryPointHTML, "<div>Suggestion</div>")
        XCTAssertFalse(result.cacheAllowed)
    }

    func testRejectsUngroundedOrUndisplayableAnswers() {
        let gpt = #"{"status":"completed","output":[{"type":"message","content":[{"type":"output_text","text":"Unsourced answer."}]}]}"#
        let claude = #"{"content":[{"type":"text","text":"Unsourced answer."}]}"#
        let gemini = #"{"candidates":[{"content":{"parts":[{"text":"Cannot show this response."}]},"groundingMetadata":{"groundingChunks":[{"web":{"uri":"https://example.org/source"}}]}}]}"#
        XCTAssertThrowsError(try OnlineAskClient.decode(Data(gpt.utf8), from: .gpt))
        XCTAssertThrowsError(try OnlineAskClient.decode(Data(claude.utf8), from: .claude))
        XCTAssertThrowsError(try OnlineAskClient.decode(Data(gemini.utf8), from: .gemini))
    }
}
