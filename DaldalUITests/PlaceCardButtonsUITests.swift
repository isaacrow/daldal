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
        app.launch()
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

    func testWalkWithAROpens() {
        let app = launchWithCard()
        app.buttons["place.walk"].tap()
        let opened = app.staticTexts[noAR].waitForExistence(timeout: 15)
        shot("after-walk")
        XCTAssertTrue(opened, "tapping Walk with AR didn't open the walking AR screen")
    }

    func testDriveScanOpensWithCardShowing() {
        let app = launchWithCard()
        app.buttons["map.scan"].tap()
        let opened = app.staticTexts[noAR].waitForExistence(timeout: 15)
        shot("after-scan")
        XCTAssertTrue(opened, "tapping Drive Scan didn't open the scan screen")
    }
}
