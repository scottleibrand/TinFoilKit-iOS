import XCTest
import ZIMArchive

final class ZIMArchiveTests: XCTestCase {
    func testReadsArticleFromLocalWikipediaArchive() throws {
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let archive = try ZIMArchive(fileURL: file)

        let article = try archive.mainArticle()
        XCTAssertEqual(article.path, "index")
        XCTAssertEqual(article.mimeType, "text/html")
        XCTAssertTrue(String(decoding: article.data, as: UTF8.self).localizedCaseInsensitiveContains("climate change"))
        XCTAssertEqual(try archive.resource(at: article.path).data, article.data)
        XCTAssertThrowsError(try archive.resource(at: "missing-entry-for-test"))
    }

    func testReportsInvalidArchive() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("Invalid archive".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertThrowsError(try ZIMArchive(fileURL: file))
    }

    func testInstalledArchiveSurvivesReopeningLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let library = InstalledLibrary(directory: directory)
        let installed = try await library.importArchive(from: file)

        let reopened = InstalledLibrary(directory: directory)
        let archives = try await reopened.archives()
        XCTAssertEqual(archives, [installed])
        XCTAssertGreaterThan(installed.byteCount, 0)
        let copy = await reopened.fileURL(for: installed.id)
        XCTAssertNotEqual(copy, file)
        XCTAssertEqual(try ZIMArchive(fileURL: copy).mainArticle().path, "index")
    }

    func testFailedImportDoesNotAppearInLibrary() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("invalid.zim")
        try Data("Invalid archive".utf8).write(to: file)
        let storage = directory.appendingPathComponent("Library")
        let library = InstalledLibrary(directory: storage)

        do {
            try await library.importArchive(from: file)
            XCTFail("An invalid archive was accepted")
        } catch {}
        let archives = try await library.archives()
        XCTAssertTrue(archives.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: storage.path).isEmpty)
    }

    func testFullTextSearchReopensAnArchivedArticle() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let library = InstalledLibrary(directory: directory)
        let installed = try await library.importArchive(from: fixture)
        let file = await library.fileURL(for: installed.id)
        let index = ArticleIndex(archiveURL: file)
        try index.build(archiveURL: file)

        let reopenedIndex = ArticleIndex(archiveURL: file)
        let matches = try reopenedIndex.search("anthropogenic")
        let match = try XCTUnwrap(matches.first {
            !$0.title.localizedCaseInsensitiveContains("anthropogenic")
                && $0.excerpt.localizedCaseInsensitiveContains("anthropogenic")
        })
        let article = try ZIMArchive(fileURL: file).resource(at: match.path)
        XCTAssertTrue(String(decoding: article.data, as: UTF8.self).localizedCaseInsensitiveContains("anthropogenic"))
    }

    func testPublisherVerificationPreservesInstalledEdition() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
        let library = InstalledLibrary(directory: directory)
        let edition = PublishedPack(
            id: "climate", title: "Climate test pack", version: "2024-06", source: fixture,
            sha256: "448327659c3981918da00f12f8427996f6bbc4efb4d5c14ba39704122483f0f4",
            sizeEstimate: 8_896_329, attribution: "Wikipedia contributors"
        )
        let installed = try await library.installPack(edition, from: fixture)
        let duplicate = try await library.installPack(edition, from: fixture)
        XCTAssertEqual(duplicate, installed)

        let badUpdate = PublishedPack(
            id: edition.id, title: edition.title, version: "2024-07", source: fixture,
            sha256: String(repeating: "0", count: 64), sizeEstimate: edition.sizeEstimate, attribution: edition.attribution
        )
        do {
            try await library.installPack(badUpdate, from: fixture)
            XCTFail("An archive with a bad checksum was accepted")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("checksum"))
        }
        let archives = try await library.archives()
        XCTAssertEqual(archives, [installed])
        let installedURL = await library.fileURL(for: installed.id)
        XCTAssertEqual(try ZIMArchive(fileURL: installedURL).mainArticle().path, "index")
    }
}
