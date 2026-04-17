import Combine
import ConvosCore
import XCTest
@testable import Convos

@MainActor
final class NewConversationViewModelRetryTests: XCTestCase {

    // MARK: - Error classification

    func testDnsErrorClassifiedAsServiceUnavailable() {
        let error = ConversationStateMachineError.stateMachineError(
            FakeXMTPError(message: "[GroupError::Client] Group error: client: API error: service is currently unavailable, self: \"dns error\"")
        )
        XCTAssertEqual(error.networkErrorKind, .serviceUnavailable)
        XCTAssertEqual(error.title, "Can't connect")
    }

    func testTimeoutErrorClassified() {
        let error = ConversationStateMachineError.timedOut
        XCTAssertEqual(error.networkErrorKind, .timedOut)
        XCTAssertEqual(error.title, "Connection timed out")
        XCTAssertEqual(error.description, "The server took too long to respond. Try again in a moment.")
    }

    func testConnectionLostClassified() {
        let error = ConversationStateMachineError.stateMachineError(
            FakeXMTPError(message: "The network connection was lost.")
        )
        XCTAssertEqual(error.networkErrorKind, .connectionLost)
        XCTAssertEqual(error.title, "No connection")
    }

    func testTLSErrorClassified() {
        let error = ConversationStateMachineError.stateMachineError(
            FakeXMTPError(message: "A TLS error caused the secure connection to fail.")
        )
        XCTAssertEqual(error.networkErrorKind, .tlsFailure)
        XCTAssertEqual(error.title, "Secure connection failed")
    }

    func testStorageErrorClassifiedAsInternal() {
        let error = ConversationStateMachineError.stateMachineError(
            FakeXMTPError(message: "[GroupError::Storage] Group error: storage error: Pool needs to reconnect before use")
        )
        XCTAssertEqual(error.networkErrorKind, .internalError)
        XCTAssertEqual(error.title, "Something went wrong")
    }

    func testUnknownErrorHasNoNetworkKind() {
        let error = ConversationStateMachineError.stateMachineError(
            FakeXMTPError(message: "Some completely unknown error")
        )
        XCTAssertNil(error.networkErrorKind)
        XCTAssertEqual(error.title, "Something went wrong")
    }

    func testNonNetworkErrorsPreserveExistingCopy() {
        XCTAssertEqual(ConversationStateMachineError.inviteExpired.title, "Invite expired")
        XCTAssertEqual(ConversationStateMachineError.conversationExpired.title, "Convo expired")
        XCTAssertEqual(ConversationStateMachineError.failedFindingConversation.title, "No convo here")
        XCTAssertEqual(ConversationStateMachineError.failedVerifyingSignature.title, "Invalid invite")
        XCTAssertEqual(ConversationStateMachineError.invalidInviteCodeFormat("bad").title, "Invalid code")
    }
}

// MARK: - Test helpers

private struct FakeXMTPError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
