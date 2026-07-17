import Foundation

/// Mock implementation of `ConversationLeaveWriterProtocol` for testing.
public final class MockConversationLeaveWriter: ConversationLeaveWriterProtocol, @unchecked Sendable {
    public struct LeaveRecord: Sendable {
        public let conversation: Conversation
        public let successorCandidates: [LeaveSuccessorCandidate]
    }

    public var leftConversations: [LeaveRecord] = []
    public var leaveError: Error?

    public init() {}

    public func leave(
        conversation: Conversation,
        successorCandidates: [LeaveSuccessorCandidate]
    ) async throws {
        if let leaveError {
            throw leaveError
        }
        leftConversations.append(
            LeaveRecord(
                conversation: conversation,
                successorCandidates: successorCandidates
            )
        )
    }
}
