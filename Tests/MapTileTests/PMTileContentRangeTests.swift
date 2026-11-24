import XCTest
@testable import TinfoilKit

final class PMTileContentRangeTests: XCTestCase {
    func testAcceptsExactRangeWithKnownOrUnknownLength() {
        XCTAssertEqual(PMTileContentRange("bytes 0-126/133", start: 0, end: 126)?.archiveLength, 133)
        let unknown = PMTileContentRange("bytes 127-131/*", start: 127, end: 131)
        XCTAssertNotNil(unknown)
        XCTAssertNil(unknown?.archiveLength)
    }

    func testRejectsInexactRangesAndInvalidLengths() {
        for value in [
            nil, "bytes 0-125/133", "bytes 1-126/133", "bytes 0-126/",
            "bytes 0-126/126", "bytes 0-126/133junk", "bytes 0-126/+133",
            "bytes 0-126/18446744073709551616", "bytes 0-126/133, bytes 0-126/133"
        ] as [String?] {
            XCTAssertNil(PMTileContentRange(value, start: 0, end: 126), value ?? "missing header")
        }
    }
}
