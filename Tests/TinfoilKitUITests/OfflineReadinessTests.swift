import XCTest

final class OfflineReadinessTests: XCTestCase {
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
