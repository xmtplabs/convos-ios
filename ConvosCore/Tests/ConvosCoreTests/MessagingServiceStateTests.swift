@testable import ConvosCore
import XCTest

final class MessagingServiceStateTests: XCTestCase {
    func testBackgroundedReadySessionRemainsAuthorized() {
        let client = MockXMTPClientProvider(inboxId: "inbox-shane")
        let ready = InboxReadyResult(client: client, apiClient: MockAPIClient())
        let stateManager = MockSessionStateManager(initialState: .backgrounded(ready))
        let service = MockMessagingService(sessionStateManager: stateManager)

        guard case .authorized(let inboxId) = service.state else {
            return XCTFail("A backgrounded ready session must retain its authorized identity")
        }
        XCTAssertEqual(inboxId, "inbox-shane")
    }

    func testAuthorizingSessionStillReportsRegistering() {
        let stateManager = MockSessionStateManager(initialState: .authorizing(inboxId: "inbox-shane"))
        let service = MockMessagingService(sessionStateManager: stateManager)

        guard case .registering = service.state else {
            return XCTFail("An authorizing session must not report an authorized identity yet")
        }
    }
}
