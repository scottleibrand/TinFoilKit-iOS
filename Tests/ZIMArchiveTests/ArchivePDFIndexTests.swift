import Foundation
import SQLite3
import XCTest
import ZIMArchive

final class ArchivePDFIndexTests: XCTestCase {
    func testMatchingPDFTextOpensItsPageAndHTMLIsAlsoIndexed() throws {
        try withArchive { file in
            let index = ArticleIndex(archiveURL: file)
            try index.build(archiveURL: file)
            XCTAssertTrue(index.isReady)

            let match = try XCTUnwrap(index.search("protozoa").first)
            let page = try XCTUnwrap(ArchivePDFReference(articlePath: match.path))
            XCTAssertEqual(page.path, "files/Water Guide.pdf")
            XCTAssertEqual(page.pageIndex, 1)
            XCTAssertTrue(match.title.hasSuffix("p. 2"))
            XCTAssertTrue(match.excerpt.localizedCaseInsensitiveContains("ceramic filtration"))
            XCTAssertFalse(match.excerpt.localizedCaseInsensitiveContains("drinking"))
            let pdf = try ZIMArchive(fileURL: file).resource(at: page.path)
            XCTAssertEqual(pdf.mimeType, "application/pdf")

            let firstPage = try XCTUnwrap(index.search("drinking").first)
            XCTAssertEqual(ArchivePDFReference(articlePath: firstPage.path)?.pageIndex, 0)
            XCTAssertEqual(try index.search("bowline").first.flatMap { ArchivePDFReference(articlePath: $0.path) }?.path,
                           "files/Knots.pdf")
            XCTAssertEqual(try index.search("two offline documents").first?.path, "index.html")
            XCTAssertTrue(try index.search("filtrat protoz").isEmpty)
            XCTAssertEqual(try index.search("filtrat, protoz", prefixMatching: true).first?.path, match.path)
            XCTAssertTrue(try index.search("filtrat drink", prefixMatching: true).isEmpty)
        }
    }

    func testPreviousIndexStaysSearchableWhilePerPageIndexBuilds() throws {
        try withArchive { file in
            let old = file.deletingLastPathComponent().appendingPathComponent("articles-v1.sqlite")
            try createPreviousIndex(at: old)
            let index = ArticleIndex(archiveURL: file)
            XCTAssertFalse(index.isReady)
            XCTAssertTrue(index.hasSearchableIndex)
            XCTAssertEqual(try index.search("legacy", prefixMatching: true).first?.path, "index.html")

            var legacyMatchesDuringBuild: [ArticleIndex.Match] = []
            try index.build(archiveURL: file) { fraction in
                guard fraction < 1 else { return }
                legacyMatchesDuringBuild = (try? index.search("legacy", includeIncomplete: true)) ?? []
            }
            XCTAssertEqual(legacyMatchesDuringBuild.first?.path, "index.html")
            XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
            XCTAssertTrue(index.isReady)
            XCTAssertTrue(try index.search("legacy").isEmpty)
            XCTAssertFalse(try index.search("protozoa").isEmpty)
        }
    }

    private func withArchive(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "pdf-collection", withExtension: "zim"))
        let file = directory.appendingPathComponent("archive.zim")
        try FileManager.default.copyItem(at: fixture, to: file)
        try body(file)
    }

    private func createPreviousIndex(at url: URL) throws {
        var connection: OpaquePointer?
        defer { sqlite3_close(connection) }
        XCTAssertEqual(sqlite3_open(url.path, &connection), SQLITE_OK)
        let db = try XCTUnwrap(connection)
        XCTAssertEqual(sqlite3_exec(db, """
            CREATE VIRTUAL TABLE articles USING fts5(path UNINDEXED, title, body);
            INSERT INTO articles VALUES ('index.html', 'Earlier index', 'legacy HTML');
            """, nil, nil, nil), SQLITE_OK)
    }
}
