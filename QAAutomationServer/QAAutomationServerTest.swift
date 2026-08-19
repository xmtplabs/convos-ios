import XCTest

final class QAAutomationServerTest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testYourSpaceHomeScrolls() throws {
        let app = XCUIApplication()
        app.launchEnvironment["YOUR_SPACE_VISUAL_FIXTURE"] = "1"
        app.launch()

        let contextSearch = app.buttons["your-space-context-search"]
        XCTAssertTrue(contextSearch.waitForExistence(timeout: 10))
        let initialY = contextSearch.frame.minY

        app.swipeUp()

        XCTAssertLessThan(contextSearch.frame.minY, initialY - 40)
    }

    @MainActor
    func testQAAutomationServer() throws {
        let app = XCUIApplication()
        app.launch()

        let handler = CommandHandler(app: app)
        let server = QAHTTPServer(handler: handler)
        try server.start()

        print("[QAAutomationServer] Ready — accepting commands on http://localhost:8615/action")
        print("[QAAutomationServer] Send POST with JSON body: {\"action\": \"observeScreen\"}")
        print("[QAAutomationServer] Available actions: observeScreen, tapElement, fillField, tapCoordinate, swipe, scrollUntilVisible, waitForElement, pressKey, longPress, doubleTap, ping")

        // Keep the test alive — this IS the server
        // It will run until the test is cancelled (Ctrl+C or Xcode stop)
        let runForever = expectation(description: "Run forever")
        runForever.isInverted = true
        wait(for: [runForever], timeout: .infinity)
    }
}
