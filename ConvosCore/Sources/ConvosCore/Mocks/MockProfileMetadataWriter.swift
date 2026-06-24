import Foundation

/// Mock `ProfileMetadataWriterProtocol` for tests/previews. Records the merged
/// metadata each `updateMetadata` produced, applying the caller's closure to an
/// empty map so callers can assert on the keys they set.
public final class MockProfileMetadataWriter: ProfileMetadataWriterProtocol, @unchecked Sendable {
    public struct Update {
        public let conversationId: String
        public let inboxId: String
        public let metadata: ProfileMetadata
    }

    public private(set) var updates: [Update] = []
    public var updateError: (any Error)?

    public init() {}

    public func updateMetadata(
        conversationId: String,
        inboxId: String,
        update: @escaping @Sendable (inout ProfileMetadata) -> Void
    ) async throws {
        var metadata: ProfileMetadata = [:]
        update(&metadata)
        updates.append(.init(conversationId: conversationId, inboxId: inboxId, metadata: metadata))
        if let updateError {
            throw updateError
        }
    }
}

/// Mock `AgentTimezonePublishing` for tests/previews. Records the conversation
/// ids it was asked to publish for and how many full republish sweeps ran.
public final class MockAgentTimezonePublisher: AgentTimezonePublishing, @unchecked Sendable {
    public private(set) var publishedConversationIds: [String] = []
    public private(set) var republishCount: Int = 0

    public init() {}

    public func publishTimezoneIfAgentConversation(conversationId: String) async {
        publishedConversationIds.append(conversationId)
    }

    public func republishTimezoneForAgentConversations() async {
        republishCount += 1
    }
}
