import Foundation
import SQLite3
import XCTest
@testable import TinfoilKit
@testable import ZIMArchive

final class LibraryArchiveSearchTests: XCTestCase {
    func testCompletedAndPartialIndexesPrecedeDeduplicatedTitleFallback() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = try archive("Completed", in: root)
        let partial = try archive("Partial", in: root)
        try writeIndex(for: completed.1, paths: ["same", "same"])
        try writeIndex(for: partial.1, paths: ["same"], partial: true)
        let cache: [UUID: [ZIMArchive.ArticleTitle]] = [
            completed.0.id: [title("same"), title("completed-alias")],
            partial.0.id: [title("same"), title("partial-alias"), title("partial-alias")]
        ]

        let output = try LibraryArchiveSearch.search("climate", in: [completed, partial], titleCache: cache)
        XCTAssertEqual(output.matches.map(\.archive.id), [completed.0.id, partial.0.id, completed.0.id, partial.0.id])
        XCTAssertEqual(output.matches.map(\.match.path), ["same", "same", "completed-alias", "partial-alias"])
        XCTAssertEqual(output.matches.map { $0.match.excerpt.isEmpty }, [false, false, true, true])
        XCTAssertEqual(output.unavailableCount, 0)
        XCTAssertEqual(output.titleCache[completed.0.id]?.map(\.path), ["same", "completed-alias"])
        let titleOnly = try XCTUnwrap(output.matches.last)
        XCTAssertNil(LibraryPassages.SearchIntent("Climate").score(titleOnly.match, rank: 0, queryOrder: 0))
    }

    func testCorruptIndexesDoNotHideOtherResultsOrCacheFailedTitleLookup() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let completed = try archive("Unreadable completed index", in: root)
        let partial = try archive("Unreadable partial index", in: root)
        let healthy = try archive("Available", in: root)
        try writeIndex(for: healthy.1, paths: ["body"])
        for file in [
            completed.1.deletingLastPathComponent().appendingPathComponent("articles-v3.sqlite"),
            partial.1.deletingLastPathComponent().appendingPathComponent(".articles-v3-in-progress.sqlite")
        ] {
            try Data("Not SQLite".utf8).write(to: file)
        }
        let previousTitles = [completed.0.id: [title("available-title")], healthy.0.id: []]
        let output = try LibraryArchiveSearch.search("climate", in: [completed, partial, healthy],
                                                    titleCache: previousTitles)

        XCTAssertEqual(output.matches.map(\.match.path), ["body", "available-title"])
        XCTAssertEqual(output.unavailableCount, 2)
        XCTAssertNil(output.titleCache[partial.0.id])
        XCTAssertEqual(output.titleCache[healthy.0.id]?.count, 0)
    }

    func testSearchPreservesCancellation() async throws {
        let search = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LibraryArchiveSearch.search("climate", in: [], titleCache: [:])
        }
        do {
            _ = try await search.value
            XCTFail("Expected search to stop when cancelled")
        } catch is CancellationError {}
    }

    func testSearchPreservesMatchesDuringMigrationWithOneInvalidIndex() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try archive("Valid staging", in: root)
        let legacy = try archive("Valid legacy", in: root)
        try writeIndex(for: staged.1, paths: ["staged"], partial: true)
        try writeIndex(for: legacy.1, paths: ["legacy"], legacy: true)
        try Data("Not SQLite".utf8).write(to: staged.1.deletingLastPathComponent()
            .appendingPathComponent("articles-v1.sqlite"))
        try Data("Not SQLite".utf8).write(to: legacy.1.deletingLastPathComponent()
            .appendingPathComponent(".articles-v3-in-progress.sqlite"))

        for (url, path) in [(staged.1, "staged"), (legacy.1, "legacy")] {
            let index = ArticleIndex(archiveURL: url)
            XCTAssertEqual(try index.search("climate", includeIncomplete: true).map(\.path), [path])
            XCTAssertThrowsError(try index.search("unrelated", includeIncomplete: true))
        }
    }

    private func archive(_ name: String, in root: URL) throws -> (InstalledArchive, URL) {
        let archive = InstalledArchive(id: UUID(), title: name, byteCount: 1, pack: nil)
        let directory = root.appendingPathComponent(archive.id.uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (archive, directory.appendingPathComponent("archive.zim"))
    }

    private func title(_ path: String) -> ZIMArchive.ArticleTitle {
        ZIMArchive.ArticleTitle(path: path, title: "Climate \(path)")
    }

    private func writeIndex(for archiveURL: URL, paths: [String], partial: Bool = false, legacy: Bool = false) throws {
        let filename = legacy ? "articles-v1.sqlite"
            : partial ? ".articles-v3-in-progress.sqlite" : "articles-v3.sqlite"
        let file = archiveURL.deletingLastPathComponent().appendingPathComponent(filename)
        var database: OpaquePointer?
        defer { sqlite3_close(database) }
        XCTAssertEqual(sqlite3_open(file.path, &database), SQLITE_OK)
        let sql = """
            CREATE VIRTUAL TABLE articles USING fts5(path UNINDEXED, title, body\(legacy ? "" : ", label UNINDEXED"));
            """
        XCTAssertEqual(sqlite3_exec(database, sql, nil, nil, nil), SQLITE_OK)
        for path in paths {
            let insert = """
                INSERT INTO articles VALUES ('\(path)', 'Climate note', 'Read the saved climate observation.'\(legacy ? "" : ", ''"));
                """
            XCTAssertEqual(sqlite3_exec(database, insert, nil, nil, nil), SQLITE_OK)
        }
    }
}
