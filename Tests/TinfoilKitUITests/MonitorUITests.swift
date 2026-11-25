import XCTest

final class MonitorUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testWashingtonUpdatesShowsTheRoadClosureOptIn() {
        let app = XCUIApplication()
        app.launchArguments = ["-nwsAlertArea", "WA", "-wsdotClosureAdvisories", "NO"]
        app.launch()
        app.tabBars.buttons["Updates"].tap()
        XCTAssertTrue(app.navigationBars["Updates"].waitForExistence(timeout: 8))
        let settings = app.buttons["Road closure settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let roadStatus = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "WSDOT road closures", "Off")
        ).firstMatch
        XCTAssertTrue(roadStatus.exists)
        settings.tap()
        XCTAssertTrue(app.navigationBars["WSDOT road closures"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.switches["Show WSDOT road closures"].value as? String, "0")
    }

    func testOregonUpdatesShowsWeatherWithoutWashingtonRoadControls() {
        let app = XCUIApplication()
        app.launchArguments = ["-nwsAlertArea", "OR", "-wsdotClosureAdvisories", "NO"]
        app.launch()
        app.tabBars.buttons["Updates"].tap()
        XCTAssertTrue(app.navigationBars["Updates"].waitForExistence(timeout: 8))
        let weather = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "NWS weather alerts", "Oregon")
        ).firstMatch
        XCTAssertTrue(weather.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Road closure settings"].exists)
    }
}
