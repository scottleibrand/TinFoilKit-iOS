import Foundation
import XCTest
@testable import TinfoilKit

final class NearbyPublicResumeTests: XCTestCase {
    func testResumeOffsetIsBoundedByPinnedLength() {
        let frame = NearbyPublicResume.request(offset: 512)
        XCTAssertEqual(frame, Data([0, 0, 2, 0]))
        XCTAssertEqual(NearbyPublicResume.offset(from: frame, byteCount: 1_977), 512)
        XCTAssertEqual(NearbyPublicResume.offset(from: Data(repeating: 0, count: 4), byteCount: 1_977), 0)
        XCTAssertNil(NearbyPublicResume.offset(from: frame, byteCount: 512))
        XCTAssertNil(NearbyPublicResume.offset(from: frame.dropLast(), byteCount: 1_977))
        XCTAssertNil(NearbyPublicResume.offset(from: Data(repeating: 255, count: 4), byteCount: 1_977))
    }

    func testReloadsOnlyAnIncompleteRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("current-digest.partial")
        XCTAssertTrue(NearbyPublicResume.load(from: file, byteCount: 8).isEmpty)

        let prefix = Data([1, 2, 3])
        try prefix.write(to: file, options: .atomic)
        XCTAssertEqual(NearbyPublicResume.load(from: file, byteCount: 8), prefix)
        XCTAssertTrue(NearbyPublicResume.load(from: file, byteCount: 3).isEmpty)

        let link = directory.appendingPathComponent("symlink.partial")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertTrue(NearbyPublicResume.load(from: link, byteCount: 8).isEmpty)
        XCTAssertTrue(NearbyPublicResume.load(from: directory, byteCount: 8).isEmpty)
    }
}
