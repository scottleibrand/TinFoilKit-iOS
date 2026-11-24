import XCTest
@testable import TinfoilKit

final class MapStorageTests: XCTestCase {
    func testMultipleImportsKeepTheirNamesAndRestoreSelection() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("Maps")
        let firstFile = root.appendingPathComponent("North area.pmtiles")
        let secondFile = root.appendingPathComponent("South area.pmtiles")
        try mapHeader().write(to: firstFile)
        try mapHeader().write(to: secondFile)

        let store = MapStorage(directory: folder, bundledMap: nil)
        let first = try await store.importMap(from: firstFile)
        let second = try await store.importMap(from: secondFile)
        let installed = try await store.installedMaps()
        XCTAssertEqual(installed.map(\.title), ["North area", "South area"])
        XCTAssertNotEqual(first.id, second.id)
        let mostRecent = try await store.current()
        XCTAssertEqual(mostRecent, second)

        _ = try await store.selectMap(first.id)
        let reopened = MapStorage(directory: folder, bundledMap: nil)
        let restored = try await reopened.current()
        XCTAssertEqual(restored, first)
        try await reopened.removeMap(first.id)
        let fallback = try await reopened.current()
        XCTAssertEqual(fallback, second)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.archive.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.archive.path))
    }

    func testLegacyMapStaysAvailableAfterImportAndBadFilesDoNotReplaceIt() async throws {
        let root = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let folder = root.appendingPathComponent("Maps")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacyFile = folder.appendingPathComponent("imported.pmtiles")
        let importFile = root.appendingPathComponent("Coast.pmtiles")
        let invalidFile = root.appendingPathComponent("Invalid.pmtiles")
        try mapHeader().write(to: legacyFile)
        try mapHeader().write(to: importFile)
        try Data("invalid map".utf8).write(to: invalidFile)

        let store = MapStorage(directory: folder, bundledMap: nil)
        let legacy = try await store.current()
        XCTAssertEqual(legacy?.archive, legacyFile)
        let imported = try await store.importMap(from: importFile)
        do {
            _ = try await store.importMap(from: invalidFile)
            XCTFail("Invalid import should fail")
        } catch is OfflineMap.MapError {}
        let current = try await store.current()
        XCTAssertEqual(current, imported)
        let installed = try await store.installedMaps()
        XCTAssertEqual(installed.map(\.archive), [legacyFile, imported.archive])
    }

    private func mapHeader() -> Data {
        var header = Data(repeating: 0, count: 127)
        header.replaceSubrange(0..<7, with: "PMTiles".utf8)
        header[7] = 3
        header[99] = 1
        header[100] = 0
        header[101] = 14
        let coordinates: [(Int, Int32)] = [(102, -1_230_000_000), (106, 470_000_000),
                                          (110, -1_220_000_000), (114, 480_000_000)]
        for (offset, value) in coordinates {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { header.replaceSubrange(offset..<(offset + 4), with: $0) }
        }
        return header
    }
}
