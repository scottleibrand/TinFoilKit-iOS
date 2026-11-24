import XCTest
@testable import TinfoilKit

final class OfflineCoverageStatusTests: XCTestCase {
    func testKnownCoverageTakesPrecedenceOverUnknownBounds() {
        XCTAssertEqual(OfflineCoverageStatus(candidates: [false, nil, true]), .inside)
        XCTAssertEqual(OfflineCoverageStatus(candidates: [false, nil]), .unknown)
        XCTAssertEqual(OfflineCoverageStatus(candidates: [false, false]), .outside)
    }
}
