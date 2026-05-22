import Combine
import Foundation

/// Mock contacts repository used by previews and the mock messaging service.
public final class MockContactsRepository: ContactsRepositoryProtocol, @unchecked Sendable {
    private let subject: CurrentValueSubject<[Contact], Never>

    public var contactsPublisher: AnyPublisher<[Contact], Never> {
        subject.eraseToAnyPublisher()
    }

    public init(contacts: [Contact] = MockContactsRepository.defaultMockContacts) {
        self.subject = .init(contacts)
    }

    public func fetchAll() throws -> [Contact] {
        subject.value
    }

    public func isContact(inboxId: String) throws -> Bool {
        subject.value.contains { $0.inboxId == inboxId }
    }

    public func isBlocked(inboxId: String) throws -> Bool {
        subject.value.first { $0.inboxId == inboxId }?.isBlocked ?? false
    }

    public func fetchContact(inboxId: String) throws -> Contact? {
        subject.value.first { $0.inboxId == inboxId }
    }

    public func sourceConversations(forIds ids: Set<String>) throws -> [String: ContactSourceConversation] {
        [:]
    }

    public func setContacts(_ contacts: [Contact]) {
        subject.send(contacts)
    }

    public static let defaultMockContacts: [Contact] = [
        .mock(displayName: "Alice"),
        .mock(displayName: "Bob"),
        .mock(displayName: "Charlie"),
        .mock(displayName: "Diana"),
    ]
}

public final class MockContactsWriter: ContactsWriterProtocol, @unchecked Sendable {
    public init() {}

    public func upsertContact(
        inboxId: String,
        addedViaConversationId: String?,
        profile: ContactProfileSnapshot
    ) async throws {}

    public func updateProfileIfNewer(
        inboxId: String,
        profile: ContactProfileSnapshot
    ) async throws {}

    public func block(inboxId: String) async throws {}

    public func unblock(inboxId: String) async throws {}
}

public final class MockContactSyncCoordinator: ContactSyncCoordinatorProtocol, @unchecked Sendable {
    public init() {}

    public func syncContactsOnFirstMessage(for conversationId: String) async throws {}

    public func syncContactsAfterMembershipChange(for conversationId: String) async throws {}

    public func hasSyncedContacts(for conversationId: String) throws -> Bool {
        false
    }
}
