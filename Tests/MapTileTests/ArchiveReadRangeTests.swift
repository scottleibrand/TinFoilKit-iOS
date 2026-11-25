import XCTest
@testable import TinfoilKit

final class ArchiveReadRangeTests: XCTestCase {
    func testSelectsClosedOpenAndSuffixRanges() {
        XCTAssertEqual(ArchiveReadRange.parse("bytes=1-3", count: 8), .partial(1..<4))
        XCTAssertEqual(ArchiveReadRange.parse("bytes=4-", count: 8), .partial(4..<8))
        XCTAssertEqual(ArchiveReadRange.parse("bytes=-3", count: 8), .partial(5..<8))
        XCTAssertEqual(ArchiveReadRange.parse("BYTES=6-99", count: 8), .partial(6..<8))
        XCTAssertEqual(ArchiveReadRange.parse("bytes=-99", count: 8), .partial(0..<8))
        XCTAssertEqual(ArchiveReadRange.partial(1..<4).contentRange(count: 8), "bytes 1-3/8")
    }

    func testBoundsEmptyAndOverflowingRequests() {
        for value in ["bytes=8-", "bytes=4-3", "bytes=-0", "bytes=999999999999999999999-"] {
            XCTAssertEqual(ArchiveReadRange.parse(value, count: 8), .unsatisfiable, value)
        }
        XCTAssertEqual(ArchiveReadRange.parse("bytes=0-2", count: 0), .unsatisfiable)
        XCTAssertEqual(ArchiveReadRange.parse("bytes=2-999999999999999999999", count: 8), .partial(2..<8))
        XCTAssertEqual(ArchiveReadRange.parse("bytes=-999999999999999999999", count: 8), .partial(0..<8))
        XCTAssertEqual(ArchiveReadRange.unsatisfiable.contentRange(count: 8), "bytes */8")
    }

    func testIgnoresUnsupportedOrMalformedRangeHeader() {
        for value in [nil, "items=0-1", "bytes=-", "bytes=+1-4", "bytes=1-2,4-5", "bytes=1--4"] as [String?] {
            XCTAssertEqual(ArchiveReadRange.parse(value, count: 8), .full, value ?? "no header")
        }
        XCTAssertNil(ArchiveReadRange.full.contentRange(count: 8))
    }
}
