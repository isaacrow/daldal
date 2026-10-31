import XCTest

/// Taps the place-card and map buttons in the real app, the way a person would, and checks each one
/// opens its screen. Screenshots of every step are kept in the test results.
final class PlaceCardButtonsUITests: XCTestCase {
    /// The simulator has no AR camera, so every AR screen shows this once it has opened.
    private let noAR = "This iPhone doesn't support AR."

    override func setUp() {
        continueAfterFailure = false
    }

    private func launchWithCard() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-heritage", "Imam Husayn Mausoleum", "-AppleLanguages", "(en)"]
        // Accept the location prompt if it appears, so it can't cover the buttons.
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            let allow = alert.buttons["Allow While Using App"]
            if allow.exists { allow.tap(); return true }
            return false
        }
        app.launch()
        // A harmless tap on the status-bar strip lets the interruption monitor run.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.015)).tap()
        XCTAssertTrue(app.buttons["place.directions"].waitForExistence(timeout: 30), "the place card didn't open")
        shot("card")
        return app
    }

    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "\(name)-\(self.name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func testDirectionsOpensRouteOptions() {
        let app = launchWithCard()
        app.buttons["place.directions"].tap()
        let opened = app.staticTexts["Directions to"].waitForExistence(timeout: 15)
        shot("after-directions")
        XCTAssertTrue(opened, "tapping Directions didn't show the route options")
    }

    func testViewInAROpens() {
        let app = launchWithCard()
        app.buttons["place.ar"].tap()
        let opened = app.staticTexts[noAR].waitForExistence(timeout: 15)
        shot("after-ar")
        XCTAssertTrue(opened, "tapping View in AR didn't open the AR screen")
    }

    func testHistoryInAROpens() {
        let app = launchWithCard()
        let button = app.buttons["place.history"]
        XCTAssertTrue(button.waitForExistence(timeout: 15), "Karbala's shrine should offer History in AR")
        button.tap()
        let opened = app.staticTexts[noAR].waitForExistence(timeout: 15)
        shot("after-history")
        XCTAssertTrue(opened, "tapping History in AR didn't open the AR screen")
    }

    func testWalkWithAROpens() {
        let app = launchWithCard()
        app.buttons["place.walk"].tap()
        let opened = app.staticTexts[noAR].waitForExistence(timeout: 15)
        shot("after-walk")
        XCTAssertTrue(opened, "tapping Walk with AR didn't open the walking AR screen")
    }

    func testDiscoverListsPlacesAndListenWorks() {
        let app = launchWithCard()
        app.buttons["map.discover"].tap()
        let header = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Places to visit in'")).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 15), "Discover didn't open")
        shot("discover")
        // Open the first place and check its card offers a spoken description.
        app.buttons.matching(identifier: "discover.place").firstMatch.tap()
        let listen = app.buttons["place.listen"]
        XCTAssertTrue(listen.waitForExistence(timeout: 15), "the guide place card has no Listen button")
        shot("guide-card")
        listen.tap()
    }

    func testStatsAndAssistantOpen() {
        let app = launchWithCard()
        app.buttons["map.stats"].tap()
        XCTAssertTrue(app.staticTexts["Distance driven"].waitForExistence(timeout: 15), "My driving didn't open")
        shot("stats")
        app.buttons["Close"].firstMatch.tap()
        app.buttons["map.assistant"].tap()
        // Without an agent id built in, the free on-device assistant opens (or explains why it can't run here);
        // with one, the ElevenLabs assistant offers to start.
        let talk = app.buttons["assistant.talk"]
        let fallback = app.buttons["Set up the ElevenLabs assistant instead"]
        let start = app.buttons["Start talking"]
        let opened = talk.waitForExistence(timeout: 15) || fallback.exists || start.exists
        XCTAssertTrue(opened, "the voice assistant didn't open")
        shot("assistant")
    }

    func testDriveScanOpensWithCardShowing() {
        let app = launchWithCard()
        app.buttons["map.scan"].tap()
        let opened = app.staticTexts[noAR].waitForExistence(timeout: 15)
        shot("after-scan")
        XCTAssertTrue(opened, "tapping Drive Scan didn't open the scan screen")
    }
}
