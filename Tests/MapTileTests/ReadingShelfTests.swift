import XCTest
@testable import TinfoilKit

final class ReadingShelfTests: XCTestCase {
    @MainActor
    func testExactBookmarksAndLatestPositionReopenIndependently() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let archiveID = UUID()
        let firstPage = ReadingLocation(archiveID: archiveID, path: "guide.pdf", pageIndex: 0)
        let lastPage = ReadingLocation(archiveID: archiveID, path: "guide.pdf", pageIndex: 9)
        let chapter = ReadingLocation(archiveID: archiveID, path: "Water", fragment: "Storage")
        let otherArchive = ReadingLocation(archiveID: UUID(), path: "Water")
        let shelf = ReadingShelf(file: file)

        try shelf.toggleBookmark(firstPage, title: "Emergency guide")
        try shelf.toggleBookmark(lastPage, title: "Emergency guide")
        try shelf.toggleBookmark(chapter, title: "Water")
        try shelf.recordVisit(firstPage, title: "Emergency guide")
        try shelf.recordVisit(chapter, title: "Water")
        try shelf.recordVisit(otherArchive, title: "Water")
        try shelf.recordVisit(lastPage, title: "Emergency guide")

        let reopened = ReadingShelf(file: file)
        XCTAssertNil(reopened.loadError)
        XCTAssertEqual(reopened.bookmarks.map(\.location), [chapter, lastPage, firstPage])
        XCTAssertEqual(reopened.recent.map(\.location), [lastPage, otherArchive, chapter])
        XCTAssertTrue(reopened.isBookmarked(firstPage))
        XCTAssertFalse(reopened.isBookmarked(otherArchive))

        try reopened.toggleBookmark(lastPage, title: "Emergency guide")
        try reopened.removeBookmark(chapter)
        try reopened.clearHistory()

        let cleared = ReadingShelf(file: file)
        XCTAssertEqual(cleared.bookmarks.map(\.location), [firstPage])
        XCTAssertTrue(cleared.recent.isEmpty)
    }

    @MainActor
    func testHistoryKeepsTheMostRecentHundredDocuments() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let archiveID = UUID()
        let shelf = ReadingShelf(file: file)
        for number in 0...100 {
            try shelf.recordVisit(ReadingLocation(archiveID: archiveID, path: "Article \(number)"), title: "")
        }
        let articleOne = ReadingLocation(archiveID: archiveID, path: "Article 1", fragment: "Section")
        try shelf.recordVisit(articleOne, title: "")

        let reopened = ReadingShelf(file: file)
        XCTAssertEqual(reopened.recent.count, 100)
        XCTAssertEqual(reopened.recent.first?.location, articleOne)
        XCTAssertEqual(reopened.recent.first?.title, "Article 1")
        XCTAssertEqual(reopened.recent.last?.location.path, "Article 2")
    }

    @MainActor
    func testUnreadableShelfIsPreserved() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let invalid = Data(#"{"version":2,"bookmarks":[],"recent":[]}"#.utf8)
        try invalid.write(to: file)
        let shelf = ReadingShelf(file: file)
        let chapter = ReadingLocation(archiveID: UUID(), path: "Water")

        XCTAssertNotNil(shelf.loadError)
        XCTAssertThrowsError(try shelf.toggleBookmark(chapter, title: "Water"))
        XCTAssertThrowsError(try shelf.clearHistory())
        XCTAssertTrue(shelf.bookmarks.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }

    @MainActor
    func testInvalidLocationsDoNotChangeShelf() throws {
        let file = temporaryFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let archiveID = UUID()
        let shelf = ReadingShelf(file: file)

        XCTAssertThrowsError(try shelf.recordVisit(
            ReadingLocation(archiveID: archiveID, path: ""), title: "Missing document"
        ))
        XCTAssertThrowsError(try shelf.toggleBookmark(
            ReadingLocation(archiveID: archiveID, path: "guide.pdf", pageIndex: -1), title: "Guide"
        ))
        XCTAssertTrue(shelf.bookmarks.isEmpty)
        XCTAssertTrue(shelf.recent.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }

    private func temporaryFile() -> URL {
        URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("reading.json")
    }
}
