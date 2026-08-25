import ConvosInvites
import ConvosMetrics
import Foundation

/// Translates the join-path error taxonomies into the single dimension the
/// `joined_conversation` funnel reports.
///
/// Three separate types classify a failed join today - the state machine's
/// own errors, the network kinds it string-matches out of underlying
/// transport errors, and the rejection the creator's device sends back over
/// the join DM. All three are computed to pick user-facing copy and were
/// otherwise discarded; these mappings are what carry them into telemetry.
public extension JoinFailureReason {
    /// A rejection reported by the conversation creator's device.
    ///
    /// `.genericFailure` stays `.unknown` deliberately: it is the creator's
    /// catch-all, and the accompanying `InviteJoinError.reason` string is
    /// what actually distinguishes those cases.
    static func from(inviteJoinErrorType errorType: InviteJoinErrorType) -> JoinFailureReason {
        switch errorType {
        case .conversationExpired: return .conversationExpired
        case .conversationNotFound: return .conversationNotFound
        case .consentNotAllowed: return .consentNotAllowed
        case .genericFailure: return .unknown
        }
    }

    /// A failure raised locally by the conversation state machine.
    ///
    /// Transport classification wins over the case itself, because
    /// `.stateMachineError` wraps the underlying error that
    /// `networkErrorKind` inspects - checking the case first would collapse
    /// every network failure into `.unknown`.
    static func from(conversationStateMachineError error: ConversationStateMachineError) -> JoinFailureReason {
        if let kind = error.networkErrorKind {
            return .from(networkErrorKind: kind)
        }

        switch error {
        case .inviteExpired: return .inviteExpired
        case .conversationExpired: return .conversationExpired
        case .failedFindingConversation: return .conversationNotFound
        case .failedVerifyingSignature: return .signatureVerificationFailed
        case .invalidInviteCodeFormat: return .invalidCodeFormat
        case .noConversationStateManager: return .inboxNeverReady
        case .timedOut: return .networkTimedOut
        case .stateMachineError, .addMembersFailed: return .unknown
        }
    }

    static func from(networkErrorKind kind: ConversationStateMachineError.NetworkErrorKind) -> JoinFailureReason {
        switch kind {
        case .serviceUnavailable: return .networkServiceUnavailable
        case .timedOut: return .networkTimedOut
        case .connectionLost: return .networkConnectionLost
        case .tlsFailure: return .networkTlsFailure
        case .internalError: return .internalStorageError
        }
    }

    /// Any error surfaced on the join path. Errors that are not state-machine
    /// errors reach analytics as `.unknown` rather than being dropped.
    static func from(joinError error: Error) -> JoinFailureReason {
        guard let stateMachineError = error as? ConversationStateMachineError else {
            return .unknown
        }
        return .from(conversationStateMachineError: stateMachineError)
    }
}
