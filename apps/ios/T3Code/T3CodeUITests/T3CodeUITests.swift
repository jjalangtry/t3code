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
        XCTAssertFalse(app.textFields["username-field"].exists)
    }

    @MainActor
    func testDebugAwaitingLoginShowsCredentials() throws {
        let app = XCUIApplication()
        app.launchArguments.append("-T3CODE_DEBUG_FORCE_AWAITING_LOGIN")
        app.launch()

        XCTAssertTrue(app.textFields["username-field"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.secureTextFields["password-field"].exists)
        XCTAssertTrue(app.buttons["connect-button"].exists)
        XCTAssertTrue(app.buttons["Sign In & Connect"].exists)
    }

    @MainActor
    func testAdvancedTokenModeRevealsTokenField() throws {
        let app = XCUIApplication()
        app.launch()

        let advancedDisclosure = app.buttons["Advanced"]
        XCTAssertTrue(advancedDisclosure.waitForExistence(timeout: 2))
        advancedDisclosure.tap()

        let tokenToggle = app.switches["advanced-token-toggle"]
        XCTAssertTrue(tokenToggle.waitForExistence(timeout: 2))
        tokenToggle.tap()

        XCTAssertTrue(app.secureTextFields["auth-token-field"].waitForExistence(timeout: 2))
    }
}
