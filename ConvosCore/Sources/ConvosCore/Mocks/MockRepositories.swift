import Combine
import Foundation

// MARK: - Mock Conversations Repository

/// Mock implementation of ConversationsRepositoryProtocol for testing
public final class MockConversationsRepository: ConversationsRepositoryProtocol, @unchecked Sendable {
    public var mockConversations: [Conversation]

    public init(conversations: [Conversation] = [.mock(), .mock(), .mock()]) {
        self.mockConversations = conversations
    }

    public var conversationsPublisher: AnyPublisher<[Conversation], Never> {
        Just(mockConversations).eraseToAnyPublisher()
    }

    public func fetchAll() throws -> [Conversation] {
        mockConversations
    }

    public func fetchAll() async throws -> [Conversation] {
        mockConversations
    }

    /// Note: this mock doesn't model the repo's `consent` scope, so a
    /// test that injects conversations with mixed consent values and
    /// queries with a narrow scope (e.g. `[.allowed]`) will see false
    /// positives. The production `ConversationsRepository` enforces
    /// the scope via the `WHERE consent IN (...)` clause in
    /// `composeOneToOne`.
    public func findOneToOne(with inboxId: String, excluding excludedConversationId: String?) throws -> Conversation? {
        mockConversations.first { conversation in
            guard conversation.id != excludedConversationId else { return false }
            let others = conversation.membersWithoutCurrent
            return others.count == 1 && others.first?.profile.inboxId == inboxId
        }
    }

    public func conversationsPublisher(withAgentTemplateId templateId: String) -> AnyPublisher<AgentTemplateConversations, Never> {
        var addedByCurrentUser: [Conversation] = []
        var addedByOthers: [Conversation] = []
        for conversation in mockConversations {
            let agentMember = conversation.members.first { member in
                member.isAgent && member.profile.agentTemplateId == templateId
            }
            guard let agentMember else { continue }
            let currentUserInboxId = conversation.members.first { $0.isCurrentUser }?.profile.inboxId
            if let inviterInboxId = agentMember.invitedBy?.inboxId, inviterInboxId == currentUserInboxId {
                addedByCurrentUser.append(conversation)
            } else {
                addedByOthers.append(conversation)
            }
        }
        let partition = AgentTemplateConversations(
            addedByCurrentUser: addedByCurrentUser,
            addedByOthers: addedByOthers
        )
        return Just(partition).eraseToAnyPublisher()
    }
}

// MARK: - Mock Conversations Count Repository

/// Mock implementation of ConversationsCountRepositoryProtocol for testing
public final class MockConversationsCountRepository: ConversationsCountRepositoryProtocol, @unchecked Sendable {
    public var mockCount: Int

    public init(count: Int = 1) {
        self.mockCount = count
    }

    public var conversationsCount: AnyPublisher<Int, Never> {
        Just(mockCount).eraseToAnyPublisher()
    }

    public func fetchCount() throws -> Int {
        mockCount
    }
}

// MARK: - Mock Pinned Conversations Count Repository

public final class MockPinnedConversationsCountRepository: PinnedConversationsCountRepositoryProtocol, @unchecked Sendable {
    public var mockCount: Int

    public init(count: Int = 0) {
        self.mockCount = count
    }

    public var pinnedCount: AnyPublisher<Int, Never> {
        Just(mockCount).eraseToAnyPublisher()
    }

    public func fetchCount() throws -> Int {
        mockCount
    }
}

// MARK: - Mock Conversation Repository

/// Mock implementation of ConversationRepositoryProtocol for testing
public final class MockConversationRepository: ConversationRepositoryProtocol, @unchecked Sendable {
    public var mockConversation: Conversation?

    public init(conversation: Conversation? = .mock()) {
        self.mockConversation = conversation
    }

    public var conversationId: String {
        mockConversation?.id ?? ""
    }

    public var myProfileRepository: any MyProfileRepositoryProtocol {
        MockMyProfileRepository()
    }

    public var conversationPublisher: AnyPublisher<Conversation?, Never> {
        Just(mockConversation).eraseToAnyPublisher()
    }

    public func fetchConversation() throws -> Conversation? {
        mockConversation
    }
}

// MARK: - Mock My Profile Repository

/// Mock implementation of MyProfileRepositoryProtocol for testing
public final class MockMyProfileRepository: MyProfileRepositoryProtocol, @unchecked Sendable {
    public var mockProfile: Profile

    public init(profile: Profile = .empty(inboxId: "mock-inbox-id")) {
        self.mockProfile = profile
    }

    public var myProfilePublisher: AnyPublisher<Profile, Never> {
        Just(mockProfile).eraseToAnyPublisher()
    }

    public func fetch() throws -> Profile {
        mockProfile
    }

    public func suspendObservation() {}

    public func resumeObservation() {}
}

// MARK: - Mock Messages Repository

/// Mock implementation of MessagesRepositoryProtocol for testing
public final class MockMessagesRepository: MessagesRepositoryProtocol, @unchecked Sendable {
    public var mockMessages: [AnyMessage]
    public var conversationId: String
    public private(set) var hasMoreMessages: Bool = false

    public init(conversationId: String = "mock-conversation-id", messages: [AnyMessage] = []) {
        self.conversationId = conversationId
        self.mockMessages = messages
    }

    public var messagesPublisher: AnyPublisher<[AnyMessage], Never> {
        Just(mockMessages).eraseToAnyPublisher()
    }

    public func fetchInitial() throws -> [AnyMessage] {
        let pageSize = 25
        let result = Array(mockMessages.suffix(pageSize))
        hasMoreMessages = mockMessages.count > pageSize
        return result
    }

    public func fetchPrevious() throws {
        hasMoreMessages = false
    }

    public var conversationMessagesResultPublisher: AnyPublisher<ConversationMessagesResult, Never> {
        Just(ConversationMessagesResult(conversationId: conversationId, messages: mockMessages, readReceipts: [], memberProfiles: [:]))
            .eraseToAnyPublisher()
    }

    public func fetchInitialResult() throws -> ConversationMessagesResult {
        let messages = try fetchInitial()
        return ConversationMessagesResult(conversationId: conversationId, messages: messages, readReceipts: [], memberProfiles: [:])
    }

    public func fetchInitialResult() async throws -> ConversationMessagesResult {
        let messages = try fetchInitial()
        return ConversationMessagesResult(conversationId: conversationId, messages: messages, readReceipts: [], memberProfiles: [:])
    }
}

// MARK: - Mock Draft Conversation Repository

/// Mock implementation of DraftConversationRepositoryProtocol for testing
public final class MockDraftConversationRepository: DraftConversationRepositoryProtocol, @unchecked Sendable {
    public var mockConversation: Conversation
    private let _messagesRepository: (any MessagesRepositoryProtocol)?

    public init(conversation: Conversation = .mock(id: "draft-123"), messagesRepository: (any MessagesRepositoryProtocol)? = nil) {
        self.mockConversation = conversation
        self._messagesRepository = messagesRepository
    }

    public var conversationId: String {
        mockConversation.id
    }

    public var messagesRepository: any MessagesRepositoryProtocol {
        _messagesRepository ?? MockMessagesRepository(conversationId: mockConversation.id)
    }

    public var myProfileRepository: any MyProfileRepositoryProtocol {
        MockMyProfileRepository()
    }

    public var conversationPublisher: AnyPublisher<Conversation?, Never> {
        Just(mockConversation).eraseToAnyPublisher()
    }

    public func fetchConversation() throws -> Conversation? {
        mockConversation
    }
}

// MARK: - Mock Photo Preferences Repository

public final class MockPhotoPreferencesRepository: PhotoPreferencesRepositoryProtocol, @unchecked Sendable {
    public var mockPreferences: PhotoPreferences?

    public init(preferences: PhotoPreferences? = nil) {
        self.mockPreferences = preferences
    }

    public func preferences(for conversationId: String) async throws -> PhotoPreferences? {
        mockPreferences
    }

    public func preferencesPublisher(for conversationId: String) -> AnyPublisher<PhotoPreferences?, Never> {
        Just(mockPreferences).eraseToAnyPublisher()
    }
}

// MARK: - Mock Photo Preferences Writer

public final class MockPhotoPreferencesWriter: PhotoPreferencesWriterProtocol, @unchecked Sendable {
    public var sendReadReceiptsValues: [String: Bool?] = [:]

    public init() {}

    public func setSendReadReceipts(_ sendReadReceipts: Bool?, for conversationId: String) async throws {
        sendReadReceiptsValues[conversationId] = sendReadReceipts
    }
}

// MARK: - Mock Voice Memo Transcript Storage

public final class MockVoiceMemoTranscriptRepository: VoiceMemoTranscriptRepositoryProtocol, @unchecked Sendable {
    public init() {}

    public func transcript(for messageId: String) async throws -> VoiceMemoTranscript? {
        nil
    }

    public func fetchAllTranscripts(in conversationId: String) throws -> [String: VoiceMemoTranscript] {
        [:]
    }

    public func transcriptPublisher(for messageId: String) -> AnyPublisher<VoiceMemoTranscript?, Never> {
        Just(nil).eraseToAnyPublisher()
    }

    public func transcriptsPublisher(in conversationId: String) -> AnyPublisher<[String: VoiceMemoTranscript], Never> {
        Just([:]).eraseToAnyPublisher()
    }
}

public final class MockVoiceMemoTranscriptWriter: VoiceMemoTranscriptWriterProtocol, @unchecked Sendable {
    public init() {}

    public func markPending(messageId: String, conversationId: String, attachmentKey: String) async throws {
    }

    public func saveCompleted(messageId: String, conversationId: String, attachmentKey: String, text: String) async throws {
    }

    public func saveFailed(messageId: String, conversationId: String, attachmentKey: String, errorDescription: String?) async throws {
    }

    public func markPermanentlyFailed(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        errorDescription: String?
    ) async throws {
    }

    public func deleteTranscript(messageId: String) async throws {
    }
}

public final class MockVoiceMemoTranscriptionService: VoiceMemoTranscriptionServicing, @unchecked Sendable {
    public init() {}

    public func enqueueIfNeeded(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        mimeType: String
    ) async {}

    public func retry(
        messageId: String,
        conversationId: String,
        attachmentKey: String,
        mimeType: String
    ) async {}

    public func hasSpeechPermission() -> Bool { true }
}

// MARK: - Mock Attachment Local State Writer

public final class MockAttachmentLocalStateWriter: AttachmentLocalStateWriterProtocol, @unchecked Sendable {
    public var migratedKeys: [String: String] = [:]

    public init() {}

    public func saveWithDimensions(
        attachmentKey: String,
        conversationId: String,
        width: Int,
        height: Int
    ) async throws {}

    public func saveWithDimensions(
        attachmentKey: String,
        conversationId: String,
        width: Int,
        height: Int,
        mimeType: String?
    ) async throws {}

    public func migrateKey(from oldKey: String, to newKey: String) async throws {
        migratedKeys[oldKey] = newKey
    }

    public func saveWaveformLevels(_ levels: [Float], for attachmentKey: String) async throws {
    }

    public func saveDuration(_ duration: Double, for attachmentKey: String) async throws {
    }
}
