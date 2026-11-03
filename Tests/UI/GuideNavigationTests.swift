import XCTest

final class GuideNavigationTests: XCTestCase {
    private func launch(onboarded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-guide.onboarded", onboarded ? "YES" : "NO"]
        app.launch()
        return app
    }

    @MainActor func testOnboardingLeadsIntoGuide() {
        let app = launch(onboarded: false)
        let start = app.buttons["onboarding.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 15))
        start.tap()
        let action = app.buttons["Action"]
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        action.tap()
        app.buttons["Weiter"].tap()
        for _ in 0..<2 {
            let skip = app.buttons["Überspringen"]
            XCTAssertTrue(skip.waitForExistence(timeout: 5))
            skip.tap()
        }
        let done = app.buttons["onboarding.done"]
        XCTAssertTrue(done.waitForExistence(timeout: 5))
        done.tap()
        XCTAssertTrue(app.tabBars.buttons["Für dich"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.tabBars.buttons["Stöbern"].exists)
    }

    @MainActor func testDetailShowsWatchLinksAndCanBeSaved() {
        let app = launch(onboarded: true)
        let browse = app.tabBars.buttons["Stöbern"]
        XCTAssertTrue(browse.waitForExistence(timeout: 15))
        browse.tap()
        app.buttons["Handverlesen"].tap()
        let tile = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guide.tile.")).firstMatch
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        tile.tap()
        XCTAssertTrue(app.links["guide.link.google"].waitForExistence(timeout: 5)
                      || app.buttons["guide.link.google"].waitForExistence(timeout: 1))
        let save = app.buttons["guide.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        save.tap()
        app.tabBars.buttons["Merkliste"].tap()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "guide.tile.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5), "Saved title should appear on the watchlist")
    }

    @MainActor func testSearchFindsPerson() {
        let app = launch(onboarded: true)
        let search = app.tabBars.buttons["Suche"]
        XCTAssertTrue(search.waitForExistence(timeout: 15))
        search.tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        field.typeText("Zendaya")
        XCTAssertTrue(app.staticTexts["Personen"].waitForExistence(timeout: 5))
    }
}
