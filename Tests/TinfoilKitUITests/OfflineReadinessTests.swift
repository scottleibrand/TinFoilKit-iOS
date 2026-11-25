import XCTest

final class OfflineReadinessTests: XCTestCase {
    func testHomeCoverageFindsInstalledRegionalPlaceAndRouteData() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TINFOILKIT_HOME_READINESS_FIXTURE"] == "1",
                          "Requires a synthetic regional bundle and saved Home on the dedicated simulator.")
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let readiness = app.buttons["Offline readiness"]
        XCTAssertTrue(readiness.waitForExistence(timeout: 10))
        readiness.tap()
        XCTAssertTrue(app.staticTexts["Coverage at Home"].waitForExistence(timeout: 5))
        for label in ["Regional places", "Offline routing"] {
            let covered = app.descendants(matching: .any).matching(
                NSPredicate(format: "label CONTAINS %@ AND (label CONTAINS %@ OR value == %@)",
                            label, "Inside coverage", "Inside coverage")
            ).firstMatch
            XCTAssertTrue(covered.waitForExistence(timeout: 10), label)
        }
        let regionalBundle = app.staticTexts["Basemap, places and routing files present"]
        for _ in 0..<8 where !regionalBundle.exists { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(regionalBundle.waitForExistence(timeout: 5))
    }

    func testOfflineReadinessOpensInstalledPDFAndItsIndexedPassage() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-askUsesOnDeviceModel", "NO"]
        app.launch()
        guard app.staticTexts["Offline Ask PDF Fixture"].waitForExistence(timeout: 8) else {
            throw XCTSkip("Stage the synthetic PDF fixture as an installed Library archive.")
        }
        app.buttons["Offline readiness"].tap()
        app.buttons["Run offline checks"].tap()
        XCTAssertTrue(app.navigationBars["Run offline checks"].waitForExistence(timeout: 5))
        app.buttons["Open a sample PDF"].tap()
        let pdf = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "PDF passed")).firstMatch
        XCTAssertTrue(pdf.waitForExistence(timeout: 10))

        let topic = app.textFields["Topic in your library"]
        XCTAssertTrue(topic.waitForExistence(timeout: 5))
        topic.tap()
        topic.typeText("ceramic filtration protozoa")
        app.buttons["Find citable passages"].tap()
        let passage = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Passage search passed")).firstMatch
        XCTAssertTrue(passage.waitForExistence(timeout: 10))
    }

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
