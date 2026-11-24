import XCTest
@testable import TinfoilKit

final class LibraryResultOrderTests: XCTestCase {
    func testMergesPerArchiveRanksAndStopsAtLimit() {
        XCTAssertEqual(LibraryResultOrder.interleave([["A1", "A2", "A3"], [], ["B1", "B2"]], limit: 4),
                       ["A1", "B1", "A2", "B2"])
    }
}
