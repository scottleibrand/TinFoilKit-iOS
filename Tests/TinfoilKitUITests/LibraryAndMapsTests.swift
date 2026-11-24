import XCTest

final class LibraryAndMapsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testLibraryCatalogAndRegionalMap() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        app.buttons["Content packs"].tap()
        XCTAssertTrue(app.staticTexts["Wikipedia Climate Change"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Wikipedia Chemistry"].exists)

        app.tabBars.buttons["Map"].tap()
        XCTAssertTrue(app.staticTexts["Seattle area"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.links["© OpenStreetMap contributors"].exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Seattle offline map"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSeattleWalkingPreview() throws {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Map"].tap()
        let places = app.buttons["Search places"]
        XCTAssertTrue(places.waitForExistence(timeout: 10))
        places.tap()
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Pike Place")
        let market = app.staticTexts["Pike Place Market"].firstMatch
        XCTAssertTrue(market.waitForExistence(timeout: 8))
        market.tap()
        let start = app.buttons["Start walk here"]
        guard start.waitForExistence(timeout: 6) else {
            throw XCTSkip("Build the Seattle walking graph to test walking previews")
        }
        start.tap()
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Seattle Aquarium")
        let aquarium = app.staticTexts["Seattle Aquarium"].firstMatch
        XCTAssertTrue(aquarium.waitForExistence(timeout: 8))
        aquarium.tap()
        let route = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Walking preview'")).firstMatch
        XCTAssertTrue(route.waitForExistence(timeout: 12))
    }

    func testImportsAndFindsArticleAfterRelaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))

        let fixture = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'Climate'")).firstMatch
        if !fixture.exists {
            if app.buttons["Import from Files"].exists {
                app.buttons["Import from Files"].tap()
            } else {
                app.buttons["Import archive"].tap()
            }
            let picker = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
            let file = picker.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Climate Test'")).firstMatch
            if !file.waitForExistence(timeout: 3) {
                if picker.buttons["Browse"].exists { picker.buttons["Browse"].tap() }
                let local = picker.staticTexts["On My iPhone"].firstMatch
                if local.waitForExistence(timeout: 4) { local.tap() }
                let folder = picker.staticTexts["Tinfoil Kit"].firstMatch
                if folder.waitForExistence(timeout: 4) { folder.tap() }
            }
            XCTAssertTrue(file.waitForExistence(timeout: 10), "The simulator Documents folder needs Climate Test.zim")
            file.tap()
            XCTAssertTrue(fixture.waitForExistence(timeout: 20))
        }

        app.terminate()
        app.launch()
        XCTAssertTrue(fixture.waitForExistence(timeout: 10))
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("anthropogenic")
        let excerpt = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'anthropogenic'")).firstMatch
        XCTAssertTrue(excerpt.waitForExistence(timeout: 70))
        excerpt.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
    }
}
