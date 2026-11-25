import XCTest

final class LibraryAndMapsTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    func testOfflineChatOpensFromAskOptions() {
        let app = XCUIApplication()
        app.launch()
        app.tabBars.buttons["Ask"].tap()
        let options = app.buttons["Ask options"]
        XCTAssertTrue(options.waitForExistence(timeout: 10))
        options.tap()
        app.buttons["Offline Chat"].tap()
        XCTAssertTrue(app.navigationBars["Offline Chat"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["On-device model unavailable"].exists ||
                      app.descendants(matching: .any)["Message"].firstMatch.exists)
        app.buttons["Done"].tap()
        XCTAssertTrue(app.navigationBars["Ask"].exists)
    }

    func testPublisherSearchOpensFromContentPacks() {
        let app = XCUIApplication()
        app.launch()
        let contentPacks = app.buttons["Content packs"]
        XCTAssertTrue(contentPacks.waitForExistence(timeout: 10))
        contentPacks.tap()
        app.buttons["Find publisher books"].tap()
        XCTAssertTrue(app.navigationBars["Find publisher books"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Book title or topic"].exists)
        XCTAssertFalse(app.buttons["Search Kiwix"].isEnabled)
    }

    func testWaterOutageAsksForTheServiceArea() {
        let app = XCUIApplication()
        app.launchArguments = ["-askUsesOnDeviceModel", "NO"]
        app.launch()
        app.tabBars.buttons["Ask"].tap()
        let question = app.descendants(matching: .any)["ask-question"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        question.tap()
        question.typeText("How long does our water supply work in a power outage?")
        XCTAssertTrue(app.textFields["Water utility or service area"].exists)
        app.buttons["ask-dismiss-keyboard"].tap()
        app.buttons["ask-submit"].tap()
        XCTAssertTrue(app.staticTexts["Enter your water utility or service area to look for a local estimate."]
            .waitForExistence(timeout: 25))
    }

    func testNearbyServiceOpensTheClosestInstalledPlaceOnMap() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-askUsesOnDeviceModel", "NO", "-mapDownloadPolicy", "off"]
        app.launch()
        app.tabBars.buttons["Ask"].tap()
        let question = app.descendants(matching: .any)["ask-question"].firstMatch
        XCTAssertTrue(question.waitForExistence(timeout: 10))
        question.tap()
        question.typeText("Where is the nearest hospital?")
        app.buttons["ask-submit"].tap()

        let central = app.staticTexts["Central Hospital"]
        guard central.waitForExistence(timeout: 8) else {
            if app.buttons["Open Map"].exists {
                throw XCTSkip("Install the synthetic regional place index and set the test Home before running.")
            }
            XCTFail("Expected the closest hospital from the synthetic place index.")
            return
        }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'distance from Home'"))
            .firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["Open in Google Maps"].firstMatch.exists)
        app.buttons["Show on map"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denyLocation = springboard.alerts.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Don' AND label ENDSWITH 'Allow'")
        ).firstMatch
        if denyLocation.waitForExistence(timeout: 3) { denyLocation.tap() }
        XCTAssertTrue(app.navigationBars["Map"].waitForExistence(timeout: 8))
        XCTAssertTrue(central.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["Open in Google Maps"].firstMatch.exists)
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

        let downloadOptions = app.buttons["Download options"].firstMatch
        XCTAssertTrue(downloadOptions.waitForExistence(timeout: 5))
        downloadOptions.tap()
        app.buttons["Allow cellular data…"].tap()
        XCTAssertTrue(app.buttons["Allow cellular data"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

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

    func testCompleteWikipediaEditionsAreListedInContentPacks() {
        let app = XCUIApplication()
        app.launch()
        let contentPacks = app.buttons["Content packs"]
        XCTAssertTrue(contentPacks.waitForExistence(timeout: 10))
        contentPacks.tap()
        for title in ["Complete English Wikipedia", "Complete English Wikipedia (text only)"] {
            let label = app.staticTexts[title].firstMatch
            for _ in 0..<8 where !label.exists { app.swipeUp(velocity: .fast) }
            XCTAssertTrue(label.exists, "Expected \(title) in the Extended library.")
        }
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

    func testImportsAndRemovesRegionalBundleFromFiles() throws {
        try verifyRegionalBundleFromFiles(folderName: "Synthetic Regional Fixture", region: "Routing test fixture")
    }

    func testImportsAndRemovesRegionalBasemapFromFiles() throws {
        try verifyRegionalBundleFromFiles(folderName: "Synthetic Regional Map Fixture", region: "Synthetic region",
                                          attribution: "Tinfoil Kit synthetic basemap fixture")
    }

    func testRestoresAndInstallsPendingRegionalDownload() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mapDownloadPolicy", "off"]
        app.launch()
        app.tabBars.buttons["Map"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denyLocation = springboard.alerts.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Don' AND label ENDSWITH 'Allow'")
        ).firstMatch
        if denyLocation.waitForExistence(timeout: 3) { denyLocation.tap() }
        let mapMenu = app.buttons["Import map data"]
        XCTAssertTrue(mapMenu.waitForExistence(timeout: 10))
        mapMenu.tap()
        app.buttons["Download regional bundle"].tap()
        let resume = app.buttons["Resume download"]
        guard resume.waitForExistence(timeout: 6) else {
            if app.textFields["HTTPS manifest URL"].exists {
                throw XCTSkip("Seed a completed synthetic pending regional download before running this test.")
            }
            XCTFail("Expected the saved download to be available for resuming.")
            return
        }
        let network = app.descendants(matching: .any).matching(
            NSPredicate(format: "label CONTAINS %@ OR value == %@", "Wi-Fi only", "Wi-Fi only")
        ).firstMatch
        XCTAssertTrue(network.exists)
        resume.tap()
        let credit = app.descendants(matching: .any)["Tinfoil Kit synthetic basemap fixture"].firstMatch
        XCTAssertTrue(credit.waitForExistence(timeout: 15))
        mapMenu.tap()
        app.buttons["Installed regional bundles"].tap()
        let region = app.staticTexts["Synthetic region"]
        XCTAssertTrue(region.waitForExistence(timeout: 5))
        app.buttons["Remove regional bundle"].tap()
        app.buttons["Remove Synthetic region"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: region)
        wait(for: [removed], timeout: 5)
    }

    private func verifyRegionalBundleFromFiles(folderName: String, region: String, attribution: String? = nil) throws {
        let app = XCUIApplication()
        app.launchArguments = ["-mapDownloadPolicy", "off"]
        app.launch()
        app.tabBars.buttons["Map"].tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let denyLocation = springboard.alerts.buttons.matching(
            NSPredicate(format: "label BEGINSWITH 'Don' AND label ENDSWITH 'Allow'")
        ).firstMatch
        if denyLocation.waitForExistence(timeout: 3) { denyLocation.tap() }
        let mapMenu = app.buttons["Import map data"]
        XCTAssertTrue(mapMenu.waitForExistence(timeout: 10))
        mapMenu.tap()
        app.buttons["Import regional bundle"].tap()

        let remotePicker = XCUIApplication(bundleIdentifier: "com.apple.DocumentsApp")
        let picker = app.buttons["Open"].waitForExistence(timeout: 3) ? app : remotePicker
        let fixture = picker.staticTexts[folderName].firstMatch
        if !fixture.waitForExistence(timeout: 3) {
            let browse = picker.tabBars.buttons["Browse"].firstMatch
            if browse.exists, !browse.isSelected { browse.tap() }
            let folder = picker.staticTexts["Tinfoil Kit"].firstMatch
            if !folder.exists {
                let local = picker.staticTexts["On My iPhone"].firstMatch
                if local.waitForExistence(timeout: 3) { local.tap() }
            }
            if folder.waitForExistence(timeout: 4) { folder.tap() }
        }
        guard fixture.waitForExistence(timeout: 5) else {
            throw XCTSkip("Copy a synthetic bundle directory named \(folderName) into Documents.")
        }
        fixture.tap()
        let manifest = picker.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'manifest'")).firstMatch
        if !manifest.waitForExistence(timeout: 3), fixture.exists {
            fixture.doubleTap()
        }
        XCTAssertTrue(manifest.waitForExistence(timeout: 6), "Open the bundle directory before confirming the selection.")
        let open = picker.buttons["Open"].firstMatch
        XCTAssertTrue(open.isEnabled)
        open.tap()
        let installFinished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: mapMenu)
        wait(for: [installFinished], timeout: 15)
        let error = app.alerts["Map error"]
        if error.exists {
            XCTFail(error.staticTexts.allElementsBoundByIndex.map(\.label).joined(separator: " · "))
            return
        }
        if let attribution {
            XCTAssertTrue(app.staticTexts[region].waitForExistence(timeout: 5))
            XCTAssertTrue(app.descendants(matching: .any)[attribution].firstMatch.exists)
        }

        mapMenu.tap()
        app.buttons["Installed regional bundles"].tap()
        XCTAssertTrue(app.navigationBars["Installed regional bundles"].waitForExistence(timeout: 5))
        let installed = app.staticTexts[region]
        XCTAssertTrue(installed.waitForExistence(timeout: 5))
        app.buttons["Remove regional bundle"].tap()
        app.buttons["Remove \(region)"].tap()
        let removed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: installed)
        wait(for: [removed], timeout: 5)
        if let attribution {
            app.buttons["Done"].tap()
            XCTAssertFalse(app.descendants(matching: .any)[attribution].firstMatch.exists)
        }
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
