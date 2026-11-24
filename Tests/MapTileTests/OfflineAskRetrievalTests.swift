import Foundation
import XCTest
import ZIMArchive
@testable import TinfoilKit

final class OfflineAskRetrievalTests: XCTestCase {
    func testFindsMatchingPDFPagesAcrossArchivesAndResolvesCitations() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pdf-collection", withExtension: "zim"))
        let library = InstalledLibrary(directory: directory)
        let first = try await library.importArchive(from: fixture)
        let second = try await library.importArchive(from: fixture)
        for archive in [first, second] {
            let file = await library.fileURL(for: archive.id)
            try ArticleIndex(archiveURL: file).build(archiveURL: file)
        }

        let result = try await LibraryPassages.search(
            question: "ceramic filtration protozoa", suggestedQueries: ["protozoa", "ceramic filtration"],
            archives: [first, second], library: library
        )
        XCTAssertEqual(result.unreadableArchives, 0)
        XCTAssertEqual(result.sources.count, 2)
        XCTAssertEqual(Set(result.sources.map(\.id)).count, 2)
        XCTAssertEqual(Set(result.sources.map(\.archive.id)), Set([first.id, second.id]))
        for index in result.sources.indices {
            let source = result.sources[index]
            let page = try XCTUnwrap(ArchivePDFReference(articlePath: source.match.path))
            XCTAssertEqual(page.path, "files/Water Guide.pdf")
            XCTAssertEqual(page.pageIndex, 1)
            let link = try XCTUnwrap(URL(string: "tinfoil-source://article/\(index + 1)"))
            XCTAssertEqual(AnswerCitations.sourceIndex(from: link, sourceCount: result.sources.count), index)
        }
        XCTAssertEqual(AnswerCitations.indices(in: "Ceramic filtration is covered in both references [1] [2].",
                                              sourceCount: result.sources.count), [0, 1])
        XCTAssertTrue(AnswerCitations.indices(in: "An invalid citation [3].", sourceCount: result.sources.count).isEmpty)
    }
}
