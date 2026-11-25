import Foundation
import XCTest
@testable import TinfoilKit
import ZIMArchive

final class PortableLibraryFolderTests: XCTestCase {
    func testMatchesKnownLocalArchivesUsingTheirActualSizes() throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let large = pack("large")
        let small = pack("small")
        let largeFile = root.appendingPathComponent("large.zim")
        let smallFile = root.appendingPathComponent("small.zim")
        try Data(repeating: 1, count: 1_000).write(to: largeFile)
        try Data(repeating: 2, count: 10).write(to: smallFile)
        try Data([3]).write(to: root.appendingPathComponent("another-book.zim"))
        try Data([3]).write(to: root.appendingPathComponent("incomplete.zim.partial"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.zim"), withDestinationURL: largeFile)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory.zim"), withIntermediateDirectories: false)

        let matches = try PortableLibraryFolder.matchingPacks(
            in: root, catalog: [large, pack("directory"), pack("linked"), small, pack("incomplete"), small]
        )
        XCTAssertEqual(matches.map(\.pack), [small, large])
        XCTAssertEqual(matches.map(\.bytes), [10, 1_000])
        XCTAssertEqual(matches.map(\.file), [smallFile, largeFile])
    }

    func testRejectsAFileInPlaceOfTheDirectory() throws {
        let file = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        try Data([1]).write(to: file)
        XCTAssertThrowsError(try PortableLibraryFolder.matchingPacks(in: file, catalog: [pack("existing")]))
    }

    private func pack(_ name: String) -> PublishedPack {
        PublishedPack(id: name, title: name, version: "2026-11", source: URL(string: "https://example.invalid/\(name).zim")!,
                      sha256: String(repeating: "a", count: 64), sizeEstimate: 99, attribution: "Fixture")
    }
}
