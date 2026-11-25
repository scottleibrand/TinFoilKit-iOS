import Foundation
import XCTest
@testable import ZIMArchive

final class ResolvedArchivePathTests: XCTestCase {
    private let alias = "\"Climate_change_is_not_real\""
    private let target = "Climate_change_denial"

    func testResolvesDirectAndRedirectPathsAndDistinguishesMissingPath() throws {
        let archive = try ZIMArchive(fileURL: climateFixture())
        XCTAssertEqual(try archive.resolvedPath(at: target), target)
        XCTAssertEqual(try archive.resolvedPath(at: alias), target)
        XCTAssertNil(try archive.resolvedPath(at: "missing-fixture-entry"))
        XCTAssertThrowsError(try archive.resolvedPath(at: "\(target)\0extra"))
    }

    func testResolutionSkipsResourceBytesAndThrowsForBrokenRedirect() throws {
        var bytes = try Data(contentsOf: climateFixture())
        let urlTable = Int(read(UInt64.self, from: bytes, at: 32))
        // The pinned fixture's first directory entry is the alias used in this test.
        let redirect = Int(read(UInt64.self, from: bytes, at: urlTable))
        XCTAssertEqual(read(UInt16.self, from: bytes, at: redirect), .max)
        let targetIndex = Int(read(UInt32.self, from: bytes, at: redirect + 8))
        let article = Int(read(UInt64.self, from: bytes, at: urlTable + targetIndex * 8))
        let clusterIndex = Int(read(UInt32.self, from: bytes, at: article + 8))
        let clusterTable = Int(read(UInt64.self, from: bytes, at: 48))
        let cluster = Int(read(UInt64.self, from: bytes, at: clusterTable + clusterIndex * 8))

        let fixture = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("zim")
        defer { try? FileManager.default.removeItem(at: fixture) }
        bytes[cluster] = 0x0f // Unrecognized cluster compression type.
        try bytes.write(to: fixture, options: .atomic)
        let corruptBlob = try ZIMArchive(fileURL: fixture)
        XCTAssertEqual(try corruptBlob.resolvedPath(at: alias), target)
        XCTAssertThrowsError(try corruptBlob.resource(at: target))

        let redirectIndex = (redirect + 8)..<(redirect + 12)
        bytes.replaceSubrange(redirectIndex, with: [0xff, 0xff, 0xff, 0xff])
        try bytes.write(to: fixture, options: .atomic)
        let invalidTarget = try ZIMArchive(fileURL: fixture)
        XCTAssertThrowsError(try invalidTarget.resolvedPath(at: alias))

        bytes.replaceSubrange(redirectIndex, with: [0, 0, 0, 0])
        try bytes.write(to: fixture, options: .atomic)
        let redirectLoop = try ZIMArchive(fileURL: fixture)
        XCTAssertThrowsError(try redirectLoop.resolvedPath(at: alias))
    }

    private func climateFixture() throws -> URL {
        try XCTUnwrap(Bundle(for: Self.self).url(forResource: "climate", withExtension: "zim"))
    }

    private func read<T: FixedWidthInteger>(_ type: T.Type, from bytes: Data, at offset: Int) -> T {
        bytes.withUnsafeBytes { T(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: type)) }
    }
}
