import XCTest

final class WatchtowerUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    func testAppLaunchesWithOneTerminalPane() throws {
        // The app should have at least one window
        XCTAssertTrue(app.windows.count > 0, "Expected at least one window")

        // There should be exactly one pane on launch
        let pane = app.otherElements.matching(identifier: "pane").firstMatch
        XCTAssertTrue(
            pane.waitForExistence(timeout: 10),
            "Expected a terminal pane to exist"
        )

        // Verify exactly one pane
        XCTAssertEqual(
            app.otherElements.matching(identifier: "pane").count, 1,
            "Expected exactly one pane on launch"
        )
    }
}
