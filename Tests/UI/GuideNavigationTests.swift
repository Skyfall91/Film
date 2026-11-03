import XCTest

final class GuideNavigationTests: XCTestCase {
    @MainActor func testAppStartsInGuideWithoutAccount() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.tabBars.buttons["Entdecken"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.tabBars.buttons["Alle Titel"].exists)
        XCTAssertTrue(app.tabBars.buttons["Merkliste"].exists)
    }

    @MainActor func testDetailShowsWatchLinksAndCanBeSaved() {
        let app = XCUIApplication()
        app.launch()
        let all = app.tabBars.buttons["Alle Titel"]
        XCTAssertTrue(all.waitForExistence(timeout: 15))
        all.tap()
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
        let app = XCUIApplication()
        app.launch()
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
