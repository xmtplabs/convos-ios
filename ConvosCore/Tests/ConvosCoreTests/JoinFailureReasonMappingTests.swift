@testable import ConvosCore
import ConvosInvites
import ConvosMetrics
import Foundation
import Testing

private struct StubUnderlyingError: Error, CustomStringConvertible {
    let description: String
}

private struct StubUnrelatedError: Error {}

@Suite("JoinFailureReason mapping")
struct JoinFailureReasonMappingTests {
    // MARK: - Creator-side rejections

    @Test("maps every creator rejection type")
    func mapsInviteJoinErrorTypes() {
        #expect(JoinFailureReason.from(inviteJoinErrorType: .conversationExpired) == .conversationExpired)
        #expect(JoinFailureReason.from(inviteJoinErrorType: .conversationNotFound) == .conversationNotFound)
        #expect(JoinFailureReason.from(inviteJoinErrorType: .consentNotAllowed) == .consentNotAllowed)
    }

    @Test("leaves the creator's catch-all as unknown so creatorReason carries the detail")
    func mapsGenericFailureToUnknown() {
        #expect(JoinFailureReason.from(inviteJoinErrorType: .genericFailure) == .unknown)
    }

    // MARK: - State machine errors

    @Test("maps the non-network state machine cases")
    func mapsStateMachineCases() {
        #expect(JoinFailureReason.from(conversationStateMachineError: .inviteExpired) == .inviteExpired)
        #expect(JoinFailureReason.from(conversationStateMachineError: .conversationExpired) == .conversationExpired)
        #expect(JoinFailureReason.from(conversationStateMachineError: .failedFindingConversation) == .conversationNotFound)
        #expect(JoinFailureReason.from(conversationStateMachineError: .failedVerifyingSignature) == .signatureVerificationFailed)
        #expect(JoinFailureReason.from(conversationStateMachineError: .invalidInviteCodeFormat("bad")) == .invalidCodeFormat)
        #expect(JoinFailureReason.from(conversationStateMachineError: .noConversationStateManager) == .inboxNeverReady)
    }

    @Test("maps .timedOut through the network classification")
    func mapsTimedOut() {
        #expect(JoinFailureReason.from(conversationStateMachineError: .timedOut) == .networkTimedOut)
    }

    // MARK: - Network classification precedence

    /// `.stateMachineError` wraps the underlying transport error, so checking
    /// the enum case before `networkErrorKind` would collapse every network
    /// failure into `.unknown`. These pin that ordering.
    @Test(
        "classifies wrapped transport errors ahead of the enum case",
        arguments: [
            ("dns error", JoinFailureReason.networkServiceUnavailable),
            ("service is currently unavailable", .networkServiceUnavailable),
            ("request timed out", .networkTimedOut),
            ("The network connection was lost.", .networkConnectionLost),
            ("A TLS error caused the secure connection to fail.", .networkTlsFailure),
            ("storage error", .internalStorageError),
            ("SequenceId not found", .internalStorageError),
        ]
    )
    func classifiesWrappedTransportErrors(message: String, expected: JoinFailureReason) {
        let error = ConversationStateMachineError.stateMachineError(StubUnderlyingError(description: message))
        #expect(JoinFailureReason.from(conversationStateMachineError: error) == expected)
    }

    @Test("falls back to unknown for an unclassifiable wrapped error")
    func unclassifiableWrappedErrorIsUnknown() {
        let error = ConversationStateMachineError.stateMachineError(StubUnderlyingError(description: "something else entirely"))
        #expect(JoinFailureReason.from(conversationStateMachineError: error) == .unknown)
    }

    // MARK: - Untyped join errors

    @Test("routes a state machine error through the typed mapping")
    func joinErrorRoutesToTypedMapping() {
        let error: Error = ConversationStateMachineError.inviteExpired
        #expect(JoinFailureReason.from(joinError: error) == .inviteExpired)
    }

    @Test("records an unrelated error as unknown rather than dropping it")
    func unrelatedErrorIsUnknown() {
        #expect(JoinFailureReason.from(joinError: StubUnrelatedError()) == .unknown)
    }
}
