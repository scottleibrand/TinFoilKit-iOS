import XCTest
@testable import TinfoilKit

final class RegionalRefreshThrottleTests: XCTestCase {
    func testInterruptedCheckCanRetryOnTheNextConnection() {
        let start = ContinuousClock.now
        var throttle = RegionalRefreshThrottle()
        XCTAssertTrue(throttle.begin(after: .seconds(30), at: start))
        XCTAssertFalse(throttle.begin(after: .seconds(30), at: start + .seconds(2)))
        throttle.connectionInterrupted()
        XCTAssertTrue(throttle.begin(after: .seconds(30), at: start + .seconds(3)))
    }

    func testSuccessfulCheckKeepsItsCooldownAcrossConnectionChanges() {
        let start = ContinuousClock.now
        var throttle = RegionalRefreshThrottle()
        XCTAssertTrue(throttle.begin(after: .seconds(60), at: start))
        throttle.finishSuccessfully()
        throttle.connectionInterrupted()
        XCTAssertFalse(throttle.begin(after: .seconds(60), at: start + .seconds(10)))
        XCTAssertTrue(throttle.begin(after: .seconds(60), at: start + .seconds(60)))
        throttle.connectionInterrupted()
        XCTAssertTrue(throttle.begin(after: .seconds(60), at: start + .seconds(61)))
    }

    func testMeteredAndOfflineConnectionsNeedPermissionAndReachability() {
        let offline = RegionalUpdateConnection(online: false, metered: false)
        let metered = RegionalUpdateConnection(online: true, metered: true)
        let unmetered = RegionalUpdateConnection(online: true, metered: false)
        XCTAssertFalse(offline.allowsRefresh(allowMetered: true))
        XCTAssertFalse(metered.allowsRefresh(allowMetered: false))
        XCTAssertTrue(metered.allowsRefresh(allowMetered: true))
        XCTAssertTrue(unmetered.allowsRefresh(allowMetered: false))
    }
}
