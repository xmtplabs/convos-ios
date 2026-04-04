import Foundation

public final class MockDMLinksRepository: DMLinksRepositoryProtocol, @unchecked Sendable {
    public init() {}

    public func findDMConversationId(originConversationId: String, memberInboxId: String) async throws -> String? {
        nil
    }

    public func findByConvoTag(_ convoTag: String) async throws -> DBDMLink? {
        nil
    }
}

public final class MockDMLinksWriter: DMLinksWriterProtocol, @unchecked Sendable {
    public var storedLinks: [(originConversationId: String, memberInboxId: String, dmConversationId: String, convoTag: String)] = []

    public init() {}

    public func store(
        originConversationId: String,
        memberInboxId: String,
        dmConversationId: String,
        convoTag: String
    ) async throws {
        storedLinks.append((originConversationId, memberInboxId, dmConversationId, convoTag))
    }
}
