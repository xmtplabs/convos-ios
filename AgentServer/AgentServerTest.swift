import XCTest

final class AgentServerTest: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    @MainActor
    func testAgentServer() throws {
        let app = XCUIApplication()
        app.launch()

        let handler = CommandHandler(app: app)
        let server = AgentHTTPServer(handler: handler)
        try server.start()

        print("[AgentServer] Ready — accepting commands on http://localhost:8615/action")
        print("[AgentServer] Send POST with JSON body: {\"action\": \"observeScreen\"}")
        print("[AgentServer] Available actions: observeScreen, tapElement, fillField, tapCoordinate, swipe, scrollUntilVisible, waitForElement, pressKey, longPress, doubleTap, ping")

        // Keep the test alive — this IS the server
        // It will run until the test is cancelled (Ctrl+C or Xcode stop)
        let runForever = expectation(description: "Run forever")
        runForever.isInverted = true
        wait(for: [runForever], timeout: .infinity)
    }
}
