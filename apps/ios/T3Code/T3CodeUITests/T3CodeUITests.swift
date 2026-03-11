import XCTest

final class T3CodeUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testConnectScreenShowsServerField() throws {
        let app = XCUIApplication()
        app.launch()

        XCTAssertTrue(app.textFields["server-host-field"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["connect-button"].exists)
    }

    @MainActor
    func testDebugAwaitingLoginShowsCredentials() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-T3CODE_DEBUG_FORCE_AWAITING_LOGIN")
        app.launch()

        XCTAssertTrue(app.textFields["username-field"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.secureTextFields["password-field"].exists)
        XCTAssertTrue(app.buttons["connect-button"].exists)
    }
}
