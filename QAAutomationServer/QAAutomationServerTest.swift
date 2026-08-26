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

        let docMaker = app.otherElements["your-space-doc-maker"]
        XCTAssertTrue(docMaker.waitForExistence(timeout: 10))

        let docLibrary = app.otherElements["your-space-doc-library"]
        XCTAssertTrue(docLibrary.waitForExistence(timeout: 3))
        let initialY = docLibrary.frame.minY

        let homeScroll = app.scrollViews["your-space-home-scroll"]
        XCTAssertTrue(homeScroll.waitForExistence(timeout: 2))
        homeScroll.swipeUp()

        XCTAssertLessThan(docLibrary.frame.minY, initialY - 40)
    }

    @MainActor
    func testYourSpaceMakesADocWithoutConnectedEngine() throws {
        let app = XCUIApplication()
        app.launchEnvironment["YOUR_SPACE_VISUAL_FIXTURE"] = "1"
        app.launch()

        let makeDoc = app.buttons["your-space-make-doc-button"]
        XCTAssertTrue(makeDoc.waitForExistence(timeout: 10))
        makeDoc.tap()

        let docInput = app.textFields["your-space-chat-input"]
        XCTAssertTrue(docInput.waitForExistence(timeout: 5))
        XCTAssertTrue((docInput.value as? String)?.contains("Make a living group doc") == true)
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
