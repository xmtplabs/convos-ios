import Combine
import Foundation

public protocol DraftConversationWriterProtocol: OutgoingMessageWriterProtocol {
    var conversationId: String { get }
    var conversationIdPublisher: AnyPublisher<String, Never> { get }
    var conversationMetadataWriter: any ConversationMetadataWriterProtocol { get }

    func createConversation() async throws
    /// Creates the conversation with deferred visibility: the row is written
    /// `isUnused = true` (hidden from the chats list) and stays hidden until
    /// a caller commits it via `SessionManagerProtocol.commitClaimedConversation`.
    /// Used by the agent builder so its auto-created draft never surfaces
    /// before the user taps Make.
    func createConversation(startsUnused: Bool) async throws
    func joinConversation(inviteCode: String) async throws
}

public extension DraftConversationWriterProtocol {
    /// Default forwards to the plain create, dropping the flag. This is
    /// for mocks and previews only - any production conformer must
    /// override it, or deferred-visibility creation silently degrades to
    /// a visible row.
    func createConversation(startsUnused: Bool) async throws {
        try await createConversation()
    }
}
