import XCTest

final class NavigationRegressionTests: XCTestCase {
    @MainActor func testSearchShowsFirstResultsWithoutWaitingForAI() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-startTab", "4"]
        app.launch()
        let suggestion = app.buttons["Düster und spannend"]
        XCTAssertTrue(suggestion.waitForExistence(timeout: 15))
        suggestion.tap()
        XCTAssertTrue(app.staticTexts["Verstanden"].waitForExistence(timeout: 5),
                      "First keyword results should appear while AI continues")
    }

    @MainActor func testCatalogDetailCanBeClosedRepeatedly() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-startTab", "2"]
        app.launch()
        let catalog = app.tabBars.buttons["Katalog"]
        XCTAssertTrue(catalog.waitForExistence(timeout: 15))
        catalog.tap()
        for _ in 0..<2 {
            let poster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalog.poster.")).firstMatch
            XCTAssertTrue(poster.waitForExistence(timeout: 10))
            poster.tap()
            let close = app.buttons["Schließen"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertTrue(close.isHittable)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 5), "The detail overlay must actually leave the screen")
            XCTAssertTrue(catalog.waitForExistence(timeout: 5))
            XCTAssertTrue(catalog.isHittable)
        }
    }
    @MainActor func testProfileEditorAndAddProfileCancelButtons() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-startTab", "0"]
        app.launch()
        let menu = app.buttons["Wer schaut?"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15), app.debugDescription)
        menu.tap()
        app.buttons["Profile verwalten"].tap()
        app.buttons["Demo bearbeiten"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Schließen", "Close", "Abbrechen"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.buttons["Demo bearbeiten"].waitForExistence(timeout: 5))
        app.buttons["Profil hinzufügen"].tap()
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        XCTAssertTrue(app.buttons["Demo bearbeiten"].waitForExistence(timeout: 5))
        app.buttons["Fertig"].tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
    }

    @MainActor func testPlayerExitStaysAvailableAfterOpening() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-startTab", "2"]
        app.launch()
        let poster = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "catalog.poster.")).firstMatch
        XCTAssertTrue(poster.waitForExistence(timeout: 15))
        poster.tap()
        let trailer = app.buttons["Trailer"].firstMatch
        for _ in 0..<6 {
            if trailer.exists && trailer.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(trailer.isHittable)
        trailer.tap()
        let close = app.buttons["player.close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        let deadline = Date().addingTimeInterval(6)
        let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= deadline }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [elapsed], timeout: 8), .completed)
        XCTAssertTrue(close.exists)
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(app.buttons["Schließen"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func testPlanPickerAndManualTVSheetCloseButtons() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-startTab", "3"]
        app.launch()
        let profileTab = app.tabBars.buttons["Profil"]
        XCTAssertTrue(profileTab.waitForExistence(timeout: 15))
        profileTab.tap()
        let settings = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Einstellungen")).firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let changePlan = app.buttons["Tarif ändern"]
        for _ in 0..<4 {
            if changePlan.exists && changePlan.isHittable { break }
            app.swipeUp()
        }
        changePlan.tap()
        let close = app.buttons["Schließen"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(changePlan.waitForExistence(timeout: 5))
        let pair = app.buttons["Apple TV verbinden"]
        for _ in 0..<4 {
            if pair.exists && pair.isHittable { break }
            app.swipeDown()
        }
        pair.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(pair.waitForExistence(timeout: 5))
        XCTAssertTrue(pair.isHittable)
    }

    @MainActor private func settleForThreeSeconds() {
        let deadline = Date().addingTimeInterval(3)
        let elapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= deadline }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [elapsed], timeout: 5), .completed)
    }

    @MainActor func testForYouDetailExitAfterMorphSettles() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-screen", "detail", "-detailID", "dune", "-startTab", "0"]
        app.launch()
        let close = app.buttons["Schließen"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 15))
        settleForThreeSeconds()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "ForYou-detail-after-three-seconds"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(close.exists)
        XCTAssertTrue(close.isHittable)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 5))
    }

    @MainActor func testCreateProfileBackAndCancelAfterCalibrationLoads() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-screen", "home", "-startTab", "0"]
        app.launch()
        let menu = app.buttons["Wer schaut?"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap()
        app.buttons["Profil erstellen"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Navigationstest")
        app.buttons["Weiter"].tap()
        let back = app.buttons["Zurück zum Profil"]
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        settleForThreeSeconds()
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "Profile-calibration-after-three-seconds"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(back.exists)
        XCTAssertTrue(back.isHittable)
        back.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, "Navigationstest")
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Schließen", "Close", "Abbrechen"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 5))
        cancel.tap()
        let discard = app.buttons["Profil verwerfen"]
        XCTAssertTrue(discard.waitForExistence(timeout: 5))
        discard.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
    }

    @MainActor func testForYouUndoRemainsVisibleWhenUnavailable() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-screen", "home", "-startTab", "0"]
        app.launch()
        let menu = app.buttons["Wer schaut?"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        settleForThreeSeconds()
        let undo = app.buttons["Rückgängig"]
        XCTAssertTrue(undo.exists)
        XCTAssertTrue(undo.isHittable, "Keep the back control visible even without an undo entry")
        XCTAssertFalse(undo.isEnabled)
        let shot = XCTAttachment(screenshot: app.screenshot()); shot.name = "ForYou-undo-at-rest"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testForYouUndoStillWorksAfterSwipeAndDelay() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-screen", "home", "-startTab", "0"]
        app.launch()
        XCTAssertTrue(app.buttons["Wer schaut?"].waitForExistence(timeout: 15))
        app.swipeLeft()
        settleForThreeSeconds()
        let undo = app.buttons["Rückgängig"]
        XCTAssertTrue(undo.isEnabled)
        XCTAssertTrue(undo.isHittable)
        undo.tap()
        XCTAssertTrue(app.buttons["Wer schaut?"].exists)
        XCTAssertFalse(undo.isEnabled)
    }

    @MainActor func testCreateProfileCancelWithKeyboardOpen() {
        let app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-screen", "home", "-startTab", "0"]
        app.launch()
        let menu = app.buttons["Wer schaut?"]
        XCTAssertTrue(menu.waitForExistence(timeout: 15))
        menu.tap(); app.buttons["Profil erstellen"].tap()
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText("Noch nicht speichern")
        settleForThreeSeconds()
        let cancel = app.buttons.matching(NSPredicate(format: "label IN %@", ["Schließen", "Close", "Abbrechen"])).firstMatch
        XCTAssertTrue(cancel.isHittable)
        // A thumb may hit the glass beside the glyph; the whole 44-point circle must work.
        cancel.coordinate(withNormalizedOffset: CGVector(dx: 0.18, dy: 0.5)).tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 5))
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
    }

}
