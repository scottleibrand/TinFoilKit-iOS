import XCTest

final class LibraryAndMapsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testHouseholdNotesSurviveSwitchingTabsAndRelaunch() {
        let app = XCUIApplication()
        let tab = app.tabBars.buttons["Household"]
        let editor = app.textViews["Household notes"]
        let note = "Household fixture " + UUID().uuidString
        app.launch()

        tab.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("\n" + note)
        app.tabBars.buttons["Library"].tap()

        app.terminate()
        app.launch()
        tab.tap()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertTrue((editor.value as? String)?.contains(note) == true)
    }

    func testLibraryCatalogAndRegionalMap() {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 10))
        app.buttons["Content packs"].tap()
        XCTAssertTrue(app.buttons["Download all"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Essentials"].waitForExistence(timeout: 5))
        let packTitles = [
            "Water Treatment Library", "Appropedia", "Field Medicine Library",
            "Simple English Wikipedia", "Wikipedia Climate Change", "Wikipedia Chemistry"
        ]
        for title in packTitles {
            let label = app.staticTexts[title]
            for _ in 0..<4 where !label.exists { app.swipeUp(velocity: .slow) }
            XCTAssertTrue(label.exists, "Missing content pack: \(title)")
        }

        app.tabBars.buttons["Map"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denyLocation = springboard.alerts.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Don' AND label ENDSWITH 'Allow'")
        ).firstMatch
        if denyLocation.waitForExistence(timeout: 3) { denyLocation.tap() }
        XCTAssertTrue(app.staticTexts["Seattle area"].waitForExistence(timeout: 10))
        let attribution = app.descendants(matching: .any)["© OpenStreetMap contributors"].firstMatch
        XCTAssertTrue(attribution.waitForExistence(timeout: 5))
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Seattle offline map"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["Import map data"].tap()
        app.buttons["Installed basemaps"].tap()
        XCTAssertTrue(app.navigationBars["Installed basemaps"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Seattle area"].exists)
        app.buttons["Done"].tap()
        app.buttons["Import map data"].tap()
        app.buttons["Installed place data"].tap()
        XCTAssertTrue(app.navigationBars["Installed place data"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Import map data"].tap()
        app.buttons["Installed routing packs"].tap()
        XCTAssertTrue(app.navigationBars["Installed routing packs"].waitForExistence(timeout: 5))
        app.buttons["Done"].tap()
        app.buttons["Import map data"].tap()
        app.buttons["Map downloads"].tap()
        XCTAssertTrue(app.navigationBars["Map downloads"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Clear saved tiles"].exists)
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
        app.launchArguments = ["-askUsesOnDeviceModel", "NO"]
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
        fixture.press(forDuration: 1)
        let verify = app.buttons["Verify checksum"]
        XCTAssertTrue(verify.waitForExistence(timeout: 5))
        verify.tap()
        let verified = app.alerts["Checksum verified"]
        XCTAssertTrue(verified.waitForExistence(timeout: 10))
        XCTAssertTrue(verified.staticTexts.containing(NSPredicate(format: "label CONTAINS 'embedded ZIM checksum'")).firstMatch.exists)
        verified.buttons["OK"].tap()

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("anthropogenic")
        let excerpt = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] 'anthropogenic'")).firstMatch
        XCTAssertTrue(excerpt.waitForExistence(timeout: 70))
        excerpt.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        let findOnPage = app.buttons["Find on page"]
        XCTAssertTrue(findOnPage.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: findOnPage)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(app.buttons["Back in archive"].isEnabled)
        XCTAssertFalse(app.buttons["Forward in archive"].isEnabled)

        let removeBookmark = app.buttons["Remove bookmark"]
        if removeBookmark.exists { removeBookmark.tap() }
        let addBookmark = app.buttons["Add bookmark"]
        XCTAssertTrue(addBookmark.waitForExistence(timeout: 5))
        addBookmark.tap()
        XCTAssertTrue(removeBookmark.waitForExistence(timeout: 5))

        app.terminate()
        app.launch()
        let readingList = app.buttons["Reading list"]
        XCTAssertTrue(readingList.waitForExistence(timeout: 10))
        readingList.tap()
        let saved = app.descendants(matching: .any)["reading-bookmark-entry"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.tap()
        XCTAssertTrue(app.webViews.firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(removeBookmark.waitForExistence(timeout: 10))

        app.tabBars.buttons["Ask"].tap()
        let question = app.descendants(matching: .any)["ask-question"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        question.tap()
        question.typeText("What is anthropogenic climate change?")
        let done = app.buttons["ask-dismiss-keyboard"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.tabBars.buttons["Library"].isHittable)
        app.buttons["ask-submit"].tap()
        XCTAssertTrue(app.staticTexts["Matching passages"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.staticTexts["Answer"].exists)
        let online = app.buttons["Ask online"]
        XCTAssertTrue(online.waitForExistence(timeout: 5))
        online.tap()
        XCTAssertTrue(app.buttons["Search Google"].waitForExistence(timeout: 5))
        for provider in ["ChatGPT", "Claude", "Google Gemini"] {
            XCTAssertTrue(app.buttons["Copy question and open \(provider)"].exists)
        }
        app.buttons["Save a web source"].tap()
        XCTAssertTrue(app.navigationBars["Saved web sources"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Source URL"].exists)
    }
}
