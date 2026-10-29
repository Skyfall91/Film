import XCTest

/// Die Live-Demo als fester Ablauf, zum Aufnehmen als Referenz und Backup.
/// Läuft nur auf Wunsch: `TEST_RUNNER_FILM_DEMO=1 xcodebuild test … -only-testing:FilmUITests/LiveDemoRecording`.
/// Die Pausen sind die Sprechzeit, sie geben den Takt der Aufnahme vor.
final class LiveDemoRecording: XCTestCase {
    private var app: XCUIApplication!

    @MainActor func testLiveDemo() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["FILM_DEMO"] == "1", "Nur für die Demo-Aufnahme")
        app = XCUIApplication()
        app.launchArguments = ["-seedDemo", "-startTab", "0"]
        app.launch()

        // 0:00 Für dich mit dem bestehenden Profil
        let who = app.buttons["Wer schaut?"]
        XCTAssertTrue(who.waitForExistence(timeout: 20))
        print("DEMO_START \(Date().timeIntervalSince1970)")
        pause(3)

        // Neues Profil im bestehenden Konto
        who.tap(); pause(1.2)
        app.buttons["Profil erstellen"].tap(); pause(1.5)
        let name = app.textFields.firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); pause(0.4)
        name.typeText("Ceren"); pause(1)
        app.buttons["Weiter"].firstMatch.tap(); pause(2.5)

        // Bekannte Filme bewerten: Wischen, wie im echten Gebrauch. „Nicht gesehen“ zählt nicht.
        for direction in ["right", "up", "left", "down", "right", "right", "left", "up"] {
            swipeCard(direction); pause(1.4)
        }
        pause(0.8)
        let next = app.buttons["Weiter"].firstMatch
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        next.tap()

        // Geschmack
        pause(6)
        let done = app.buttons["Fertig"].firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 10))
        done.tap()

        // Zusammenschauen: Beide Profile sind aktiv, die Karte begründet für beide
        pause(6)
        cardCenter.tap(); pause(4)
        app.swipeUp(); pause(2.5)
        // Das X oben rechts, erst wenn die Seite ausgerollt ist (sonst stoppt der Tipp nur das Scrollen).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.913, dy: 0.092)).tap(); pause(2)
        XCTAssertTrue(app.tabBars.buttons["Profil"].isHittable)
        swipeCard("left"); pause(3)

        // Profil: Geschmack und Bewertungen
        app.tabBars.buttons["Profil"].tap(); pause(4)
        app.swipeUp(); pause(3)

        // Suche: vorbereiteter Satz
        app.tabBars.buttons["Suche"].tap(); pause(1.5)
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); pause(0.5)
        field.typeText("Was Lustiges unter 2 Stunden"); pause(0.6)
        field.typeText("\n"); pause(7)
        app.swipeUp(); pause(3)
        print("DEMO_END \(Date().timeIntervalSince1970)")
    }

    private var cardCenter: XCUICoordinate { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.45)) }

    /// Eine Karte von Hand wegwischen, so sieht es in der Aufnahme echt aus.
    private func swipeCard(_ direction: String) {
        let offset: CGVector = switch direction {
        case "left": CGVector(dx: -0.45, dy: 0.02)
        case "right": CGVector(dx: 0.45, dy: 0.02)
        case "up": CGVector(dx: 0.02, dy: -0.4)
        default: CGVector(dx: 0.02, dy: 0.4)
        }
        let start = cardCenter
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5 + offset.dx, dy: 0.45 + offset.dy))
        start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0)
    }

    private func pause(_ seconds: TimeInterval) {
        let until = Date().addingTimeInterval(seconds)
        let wait = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in Date() >= until }, object: nil)
        _ = XCTWaiter.wait(for: [wait], timeout: seconds + 1)
    }
}
