import XCTest
@testable import TinfoilKit

final class OnlineAskCacheTests: XCTestCase {
    func testUserSavedWebSourcesAreSearchableAfterReopeningAndCanBeRemoved() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let citation = OnlineAskCitation(url: URL(string: "https://example.com/utility")!,
                                        title: "Water utility guide", excerpt: nil)
        let source = OnlineAskSavedSource(citation: citation, resolvedURL: nil,
                                          text: "The backup generator supplies reservoir pumps.", note: nil)
        let cache = OnlineAskCache(directory: folder)
        try await cache.saveWebSource(source)
        try await cache.saveWebSource(source)

        let reopened = OnlineAskCache(directory: folder)
        let matched = try await reopened.searchWebSources("Which generator supplies the reservoir pumps?")
        XCTAssertEqual(matched.map(\.id), [source.id])
        XCTAssertEqual(matched.first?.text, source.text)
        let unrelated = try await reopened.searchWebSources("crochet hat")
        XCTAssertTrue(unrelated.isEmpty)
        try await reopened.removeWebSource(source.id)
        let remaining = try await reopened.webSources()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testSourcesCanAnswerAnotherOfflineSearchAfterReopening() async throws {
        let folder = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let citation = OnlineAskCitation(
            url: URL(string: "https://example.com/utility")!, title: "Water utility guide", excerpt: nil
        )
        let source = OnlineAskSavedSource(
            citation: citation, resolvedURL: nil,
            text: "The backup generator supplies electricity to reservoir pumps.", note: nil
        )
        let response = OnlineAskSavedAnswer(provider: .gpt, question: "What happens during a power outage?",
                                            answer: "Pressure can change.", sources: [source])
        try await OnlineAskCache(directory: folder).save(response)

        let reopened = OnlineAskCache(directory: folder)
        let retrieved = try await reopened.search("Which generator supplies the reservoir pumps?")
        XCTAssertEqual(retrieved.first?.id, response.id)
        XCTAssertEqual(retrieved.first?.sources.first?.text, source.text)
        let unrelated = try await reopened.search("How do you crochet a hat?")
        XCTAssertTrue(unrelated.isEmpty)
    }
}
