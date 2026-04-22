import Foundation
@preconcurrency import XMTPiOS

/// Mock implementation of XMTPClientProvider for testing
public final class MockXMTPClientProvider: XMTPClientProvider, @unchecked Sendable {
    public var installationId: String
    public var inboxId: String
    public var conversationsProvider: any ConversationsProvider

    public init(
        installationId: String = "mock-installation-id",
        inboxId: String = "mock-inbox-id"
    ) {
        self.installationId = installationId
        self.inboxId = inboxId
        self.conversationsProvider = MockConversationsProvider()
    }

    public func signWithInstallationKey(message: String) throws -> Data {
        Data()
    }

    public func verifySignature(message: String, signature: Data) throws -> Bool {
        true
    }

    public func messageSender(for conversationId: String) async throws -> (any MessageSender)? {
        MockMessageSender()
    }

    public func canMessage(identity: String) async throws -> Bool {
        true
    }

    public func canMessage(identities: [String]) async throws -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: identities.map { ($0, true) })
    }

    public func prepareConversation() throws -> any GroupConversationSender {
        MockGroupConversationSender()
    }

    public func newConversation(
        with memberInboxIds: [String],
        name: String,
        description: String,
        imageUrl: String
    ) async throws -> String {
        UUID().uuidString
    }

    public func newConversation(with memberInboxId: String) async throws -> any MessageSender {
        MockMessageSender()
    }

    public func conversation(with id: String) async throws -> XMTPiOS.Conversation? {
        nil
    }

    public func inboxId(for ethereumAddress: String) async throws -> String? {
        nil
    }

    public func update(consent: Consent, for conversationId: String) async throws {
        // No-op for mock
    }

    public func revokeInstallations(signingKey: any SigningKey, installationIds: [String]) async throws {
        // No-op for mock
        revokeCalls.append((signingKey, installationIds))
    }

    public var revokeCalls: [(signingKey: any SigningKey, installationIds: [String])] = []
    public var stubInboxState: XMTPiOS.InboxState?
    public var inboxStateError: (any Error)?

    public func inboxState(refreshFromNetwork: Bool) async throws -> XMTPiOS.InboxState {
        if let error = inboxStateError {
            throw error
        }
        guard let state = stubInboxState else {
            fatalError("MockXMTPClientProvider.inboxState called without stubInboxState set")
        }
        return state
    }

    public var createArchiveCalls: [(path: String, encryptionKey: Data)] = []
    public var createArchiveError: (any Error)?

    public func createArchive(path: String, encryptionKey: Data) async throws {
        createArchiveCalls.append((path, encryptionKey))
        if let error = createArchiveError {
            throw error
        }
        // Produce a placeholder file at the path so callers that stat
        // the result see it exists.
        try? Data("mock-archive".utf8).write(to: URL(fileURLWithPath: path))
    }

    public var importArchiveCalls: [(path: String, encryptionKey: Data)] = []
    public var importArchiveError: (any Error)?

    public func importArchive(path: String, encryptionKey: Data) async throws {
        importArchiveCalls.append((path, encryptionKey))
        if let error = importArchiveError {
            throw error
        }
    }

    public func deleteLocalDatabase() throws {
        // No-op for mock
    }

    public func reconnectLocalDatabase() async throws {
        // No-op for mock
    }

    public func dropLocalDatabaseConnection() throws {
        // No-op for mock
    }
}

/// Mock implementation of ConversationsProvider for testing
public final class MockConversationsProvider: ConversationsProvider, @unchecked Sendable {
    public init() {}

    // swiftlint:disable:next function_parameter_count
    public func listGroups(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        lastActivityBeforeNs: Int64?,
        limit: Int?,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy
    ) throws -> [Group] {
        []
    }

    // swiftlint:disable:next function_parameter_count
    public func list(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        limit: Int?,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy
    ) async throws -> [XMTPiOS.Conversation] {
        []
    }

    // swiftlint:disable:next function_parameter_count
    public func listDms(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        limit: Int?,
        consentStates: [ConsentState]?,
        orderBy: ConversationsOrderBy
    ) throws -> [Dm] {
        []
    }

    public func stream(
        type: ConversationFilterType,
        onClose: (() -> Void)?
    ) -> AsyncThrowingStream<XMTPiOS.Conversation, any Error> {
        AsyncThrowingStream { _ in }
    }

    public func findConversation(conversationId: String) async throws -> XMTPiOS.Conversation? {
        nil
    }

    public func findOrCreateDm(with peerInboxId: String) async throws -> XMTPiOS.Dm {
        fatalError("not implemented in mock")
    }

    public func sync() async throws {
        // No-op for mock
    }

    public func findMessage(messageId: String) throws -> DecodedMessage? {
        nil
    }

    public func syncAllConversations(consentStates: [ConsentState]?) async throws -> GroupSyncSummary {
        GroupSyncSummary(numEligible: 0, numSynced: 0)
    }

    public func streamAllMessages(
        type: ConversationFilterType,
        consentStates: [ConsentState]?,
        onClose: (() -> Void)?
    ) -> AsyncThrowingStream<DecodedMessage, any Error> {
        AsyncThrowingStream { _ in }
    }
}
