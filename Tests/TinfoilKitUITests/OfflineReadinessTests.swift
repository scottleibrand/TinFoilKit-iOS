import XCTest

final class OfflineReadinessTests: XCTestCase {
    func testOfflineReadinessAnswerCheckRespectsAskSetting() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-askUsesOnDeviceModel", "NO"]
        app.launch()
        let readiness = app.buttons["Offline readiness"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 10))
        readiness.tap()
        app.buttons["Run offline checks"].tap()
        XCTAssertTrue(app.navigationBars["Run offline checks"].waitForExistence(timeout: 5))
        app.buttons["Try an on-device answer"].tap()
        let result = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "On-device answer unavailable")).firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
    }
}
