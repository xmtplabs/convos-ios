import Combine
import Foundation
import UIKit
import XMTPiOS

public final class MockMessagingService: MessagingServiceProtocol, @unchecked Sendable {
    public let currentUser: ConversationMember = .mock()
    public let allUsers: [ConversationMember]
    public let _conversations: [Conversation]

    private var unpublishedMessages: [AnyMessage] = []

    private var currentConversation: Conversation?
    private var messages: [AnyMessage]
    private var messagesSubject: CurrentValueSubject<[AnyMessage], Never>
    private var messageTimer: Timer?

    public init() {
        let users = Self.randomUsers()
        allUsers = users
        _conversations = Self.randomConversations(with: users)
        currentConversation = _conversations.randomElement()
        let initialMessages = Self.generateRandomMessages(
            count: Int.random(in: 5...50),
            conversation: currentConversation ?? _conversations[0],
            users: allUsers
        )
        self.messages = initialMessages
        self.messagesSubject = CurrentValueSubject(initialMessages)
    }

    // MARK: - Protocol Conformance

    public func stop() {}

    public func stopAndDelete() {}

    public func stopAndDelete() async {}

    public var inboxStateManager: any InboxStateManagerProtocol {
        self
    }

    public func myProfileWriter() -> any MyProfileWriterProtocol {
        self
    }

    public func conversationStateManager() -> any ConversationStateManagerProtocol {
        MockConversationStateManager()
    }

    public var clientPublisher: AnyPublisher<(any XMTPClientProvider)?, Never> {
        Just(self).eraseToAnyPublisher()
    }

    public func conversationConsentWriter() -> any ConversationConsentWriterProtocol {
        self
    }

    public func messageWriter(for conversationId: String) -> any OutgoingMessageWriterProtocol {
        self
    }

    public func conversationLocalStateWriter() -> any ConversationLocalStateWriterProtocol {
        MockConversationLocalStateWriter()
    }

    public func conversationMetadataWriter() -> any ConversationMetadataWriterProtocol {
        MockConversationMetadataWriter()
    }

    public func conversationPermissionsRepository() -> any ConversationPermissionsRepositoryProtocol {
        MockConversationPermissionsRepository()
    }

    public func uploadImage(data: Data, assetKey: String) async throws -> String {
        // Return the asset key for testing
        assetKey
    }

    public func uploadImageAndExecute(
        data: Data,
        assetKey: String,
        afterUpload: @escaping (String) async throws -> Void
    ) async throws -> String {
        try await afterUpload(assetKey)
        return assetKey
    }
}

extension MockMessagingService: InboxStateManagerProtocol {
    public var currentState: InboxStateMachine.State {
        .idle(clientId: "mock-messaging-service")
    }

    public func waitForInboxReadyResult() async throws -> InboxReadyResult {
        .init(client: self, apiClient: MockAPIClient())
    }

    public func delete() async throws {}

    public func addObserver(_ observer: any InboxStateObserver) {
    }

    public func removeObserver(_ observer: any InboxStateObserver) {
    }

    public func reauthorize(inboxId: String, clientId: String) async throws -> InboxReadyResult {
        .init(client: self, apiClient: MockAPIClient())
    }

    public func observeState(_ handler: @escaping (InboxStateMachine.State) -> Void) -> StateObserverHandle {
        .init(observer: .init(handler: { _ in }), manager: self)
    }
}

extension MockMessagingService: InviteRepositoryProtocol {
    public var invitePublisher: AnyPublisher<Invite?, Never> {
        Just(.mock()).eraseToAnyPublisher()
    }
}

extension MockMessagingService: MyProfileWriterProtocol {
    public func update(displayName: String, conversationId: String) {
    }

    public func update(avatar: UIImage?, conversationId: String) async throws {
    }
}

extension MockMessagingService: ConversationsRepositoryProtocol {
    public var conversationsPublisher: AnyPublisher<[Conversation], Never> {
        Just(_conversations).eraseToAnyPublisher()
    }

    public func fetchAll() throws -> [Conversation] {
        _conversations
    }
}

extension MockMessagingService: ConversationsCountRepositoryProtocol {
    public var conversationsCount: AnyPublisher<Int, Never> {
        Just(1).eraseToAnyPublisher()
    }

    public func fetchCount() throws -> Int {
        1
    }
}

extension MockMessagingService: ConversationConsentWriterProtocol {
    public func join(conversation: Conversation) async throws {
    }

    public func delete(conversation: Conversation) async throws {
    }

    public func deleteAll() async throws {
    }
}

extension MockMessagingService: ConversationRepositoryProtocol {
    public var myProfileRepository: any MyProfileRepositoryProtocol {
        MockMyProfileRepository()
    }

    public var conversationId: String {
        conversation?.id ?? ""
    }

    public var conversation: Conversation? {
        _conversations.randomElement()
    }

    public var conversationPublisher: AnyPublisher<Conversation?, Never> {
        Just(conversation).eraseToAnyPublisher()
    }

    public func fetchConversation() throws -> Conversation? {
        conversation
    }
}

extension MockMessagingService: MessagesRepositoryProtocol {
    public var messagesPublisher: AnyPublisher<[AnyMessage], Never> {
        messagesSubject.eraseToAnyPublisher()
    }

    public func fetchInitial() throws -> [AnyMessage] {
        // Return the last 25 messages (or all if less than 25) to match default page size
        let pageSize = 25
        return Array(messages.suffix(pageSize))
    }

    public func fetchPrevious() throws {
        // For mock, results are delivered through the publisher
        // No action needed as messages are already available
    }

    public var hasMoreMessages: Bool {
        // For mock, return false since we don't have real pagination
        false
    }

    public var conversationMessagesPublisher: AnyPublisher<ConversationMessages, Never> {
        let conversationId = currentConversation?.id ?? ""
        return messagesSubject
            .map { (conversationId, $0) }
            .eraseToAnyPublisher()
    }
}

extension MockMessagingService: OutgoingMessageWriterProtocol {
    public var sentMessage: AnyPublisher<String, Never> {
        Just("").eraseToAnyPublisher()
    }

    public func send(text: String) async throws {
        _ = try await prepare(text: text)
        try await publish()
    }
}

extension MockMessagingService: ConversationSender {
    public var id: String {
        "conversationId"
    }

    public func add(members inboxIds: [String]) async throws {
    }

    public func remove(members inboxIds: [String]) async throws {
    }

    public func ensureInviteTag() async throws {
    }
}

class MockConversations: ConversationsProvider {
    // swiftlint:disable:next function_parameter_count
    func list(
        createdAfterNs: Int64?,
        createdBeforeNs: Int64?,
        lastActivityBeforeNs: Int64?,
        lastActivityAfterNs: Int64?,
        limit: Int?,
        consentStates: [XMTPiOS.ConsentState]?,
        orderBy: XMTPiOS.ConversationsOrderBy
    ) async throws -> [XMTPiOS.Conversation] {
        []
    }

    // swiftlint:disable:next function_parameter_count
    func listGroups(
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
    func listDms(
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

    func stream(
        type: XMTPiOS.ConversationFilterType,
        onClose: (() -> Void)?
    ) -> AsyncThrowingStream<XMTPiOS.Conversation, any Error> {
        AsyncThrowingStream { _ in
        }
    }

    func syncAllConversations(consentStates: [XMTPiOS.ConsentState]?) async throws -> GroupSyncSummary {
        .init(numEligible: 0, numSynced: 0)
    }

    func sync() async throws {
    }

    func findConversation(conversationId: String) async throws -> XMTPiOS.Conversation? {
        nil
    }

    func streamAllMessages(
        type: ConversationFilterType,
        consentStates: [ConsentState]?,
        onClose: (() -> Void)?
    ) -> AsyncThrowingStream<DecodedMessage, any Error> {
        AsyncThrowingStream { _ in
        }
    }
}

extension MockMessagingService: XMTPClientProvider, GroupConversationSender {
    public var state: MessagingServiceState {
        .authorized(inboxId)
    }

    public var inboxId: String {
        "mock-inbox-id"
    }

    public func newConversation(with memberInboxId: String) async throws -> any MessageSender {
        self
    }

    public var installationId: String {
        ""
    }

    public func signWithInstallationKey(message: String) throws -> Data {
        Data()
    }

    public func verifySignature(message: String, signature: Data) throws -> Bool {
        true
    }

    public func canMessage(identity: String) async throws -> Bool {
        true
    }

    public func canMessage(identities: [String]) async throws -> [String: Bool] {
        return Dictionary(uniqueKeysWithValues: identities.map { ($0, true) })
    }

    public func prepareConversation() throws -> GroupConversationSender {
        self
    }

    public func newConversation(with memberInboxIds: [String],
                                name: String,
                                description: String,
                                imageUrl: String) async throws -> String {
        return UUID().uuidString
    }

    public func newConversation(with memberInboxId: String) async throws -> String {
        return UUID().uuidString
    }

    public func conversation(with id: String) async throws -> XMTPiOS.Conversation? {
        nil
    }

    public var conversationsProvider: ConversationsProvider {
        MockConversations()
    }

    public func messageSender(for conversationId: String) async throws -> (any MessageSender)? {
        self
    }

    public func inboxId(for ethereumAddress: String) async throws -> String? {
        nil
    }

    public func update(consent: Consent, for conversationId: String) async throws {
    }

    public func deleteLocalDatabase() throws {
    }

    public func dropLocalDatabaseConnection() throws {
    }

    public func reconnectLocalDatabase() async throws {
    }

    public func revokeInstallations(signingKey: any SigningKey, installationIds: [String]) async throws {
    }

    public func permissionPolicySet() throws -> PermissionPolicySet {
        .init(
            addMemberPolicy: .unknown,
            removeMemberPolicy: .unknown,
            addAdminPolicy: .unknown,
            removeAdminPolicy: .unknown,
            updateGroupNamePolicy: .unknown,
            updateGroupDescriptionPolicy: .unknown,
            updateGroupImagePolicy: .unknown,
            updateMessageDisappearingPolicy: .unknown
        )
    }

    public func updateAddMemberPermission(newPermissionOption: PermissionOption) async throws {
    }
}

extension MockMessagingService: MessageSender {
    public func sendExplode(expiresAt: Date) async throws {}

    public func prepare(text: String) async throws -> String {
        guard let conversation = currentConversation else { return "" }
        let message: AnyMessage = .message(
            .init(
                id: UUID().uuidString,
                conversation: conversation,
                sender: ConversationMember(profile: currentUser.profile, role: .member, isCurrentUser: true),
                source: .outgoing,
                status: .published,
                content: .text(text),
                date: Date(),
                reactions: []
            ),
            .inserted
        )
        unpublishedMessages.append(message)
        return message.base.id
    }

    public func publish() async throws {
        messages.append(contentsOf: unpublishedMessages)
        unpublishedMessages.removeAll()
        messagesSubject.send(messages)
    }

    public func consentState() throws -> ConsentState {
        .allowed
    }
}

// MARK: - Mock Data Generation

extension MockMessagingService {
    static func randomConversations(with users: [ConversationMember]) -> [Conversation] {
        (0..<Int.random(in: 10...50)).map { index in
            Self.generateRandomConversation(id: "\(index)", from: users)
        }
    }

    static func randomUsers() -> [ConversationMember] {
        [
            .mock(name: "Alice Johnson"),
            .mock(name: "Bob Smith"),
            .mock(name: "Carol Williams"),
            .mock(name: "David Brown"),
            .mock(name: "Emma Davis"),
            .mock(name: "Frank Miller"),
            .mock(name: "Grace Wilson"),
            .mock(name: "Henry Taylor"),
            .mock(name: "Isabella Martinez"),
            .mock(name: "James Anderson")
        ]
    }

    static func generateRandomConversation(id: String, from users: [ConversationMember]) -> Conversation {
        var availableUsers = users
        // swiftlint:disable:next force_unwrapping
        let randomCreator = availableUsers.randomElement()!
        availableUsers.removeAll { $0 == randomCreator }

        let isDirectMessage = Bool.random()
        let kind: ConversationKind = isDirectMessage ? .dm : .group

        let memberCount = isDirectMessage ? 1 : Int.random(in: 1..<availableUsers.count)
        // swiftlint:disable:next force_unwrapping
        let otherMember = isDirectMessage ? availableUsers.randomElement()! : nil
        // swiftlint:disable:next force_unwrapping
        let randomMembers = isDirectMessage ? [otherMember!, randomCreator] : Array(
            availableUsers.shuffled().prefix(memberCount)
        )

        // swiftlint:disable:next force_unwrapping
        let randomName = isDirectMessage ? otherMember!.profile.displayName : [
            "Team Discussion",
            "Project Planning",
            "Coffee Chat",
            "Weekend Plans",
            "Book Club",
            "Gaming Group",
            "Study Group"
        // swiftlint:disable:next force_unwrapping
        ].randomElement()!

        return .mock(
            id: id,
            creator: randomCreator,
            date: Date(),
            consent: id == "1" ? .allowed : Consent.allCases.randomElement() ?? .allowed,
            kind: kind,
            name: randomName,
            members: randomMembers,
            otherMember: otherMember,
            messages: [],
            lastMessage: .init(
                text: TextGenerator.getString(
                    of: Int.random(in: 1...10)),
                createdAt: Date().addingTimeInterval(-TimeInterval.random(in: 0...86400))
            )
        )
    }

    private func startMessageTimer() {
        messageTimer?.invalidate()
        scheduleNextMessage()
    }

    private func scheduleNextMessage() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let interval = TimeInterval.random(in: 0.0...2.0)
            messageTimer = Timer.scheduledTimer(
                timeInterval: interval,
                target: self,
                selector: #selector(handleTimer),
                userInfo: nil,
                repeats: false
            )
        }
    }

    @objc
    private func handleTimer() {
        generateRandomMessageAndAppend()
        scheduleNextMessage()
    }

    private func generateRandomMessageAndAppend() {
        guard let conversation = currentConversation ?? _conversations.first else { return }
        let sender = conversation.members.randomElement() ?? allUsers.randomElement() ?? currentUser
        let message = Message(
            id: UUID().uuidString,
            conversation: conversation,
            sender: sender,
            source: .incoming,
            status: .published,
            content: .text(TextGenerator.getString(of: Int.random(in: 1...20))),
            date: Date(),
            reactions: []
        )
        let anyMessage = AnyMessage.message(message, .inserted)
        messages.append(anyMessage)
        messagesSubject.send(messages)
    }

    static func generateRandomMessages(
        count: Int,
        conversation: Conversation,
        users: [ConversationMember]
    ) -> [AnyMessage] {
        (0..<count).map { _ in
            let sender = conversation.members.randomElement() ?? users.randomElement() ?? users[0]
            let message = Message(
                id: UUID().uuidString,
                conversation: conversation,
                sender: sender,
                source: .incoming,
                status: .published,
                content: .text(TextGenerator.getString(of: Int.random(in: 1...20))),
                date: Date(),
                reactions: []
            )
            return AnyMessage.message(message, .existing)
        }
    }
}

// Add a mock implementation for ConversationLocalStateWriterProtocol
public class MockConversationLocalStateWriter: ConversationLocalStateWriterProtocol {
    public init() {}
    public func setUnread(_ isUnread: Bool, for conversationId: String) async throws {}
    public func setPinned(_ isPinned: Bool, for conversationId: String) async throws {}
    public func setMuted(_ isMuted: Bool, for conversationId: String) async throws {}
}

// Add mock implementations for conversation functionality
public class MockConversationMetadataWriter: ConversationMetadataWriterProtocol {
    public init() {}
    public func updateName(_ name: String, for conversationId: String) async throws {}
    public func updateDescription(_ description: String, for conversationId: String) async throws {}
    public func updateImageUrl(_ imageURL: String, for conversationId: String) async throws {}
    public func addMembers(_ memberInboxIds: [String], to conversationId: String) async throws {}
    public func removeMembers(_ memberInboxIds: [String], from conversationId: String) async throws {}
    public func promoteToAdmin(_ memberInboxId: String, in conversationId: String) async throws {}
    public func demoteFromAdmin(_ memberInboxId: String, in conversationId: String) async throws {}
    public func promoteToSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {}
    public func demoteFromSuperAdmin(_ memberInboxId: String, in conversationId: String) async throws {}
    public func updateImage(_ image: UIImage, for conversation: Conversation) async throws {}
    public func updateExpiresAt(_ expiresAt: Date, for conversationId: String) async throws {}
}

class MockConversationPermissionsRepository: ConversationPermissionsRepositoryProtocol {
    func addAdmin(memberInboxId: String, to conversationId: String) async throws {
    }

    func removeAdmin(memberInboxId: String, from conversationId: String) async throws {
    }

    func addSuperAdmin(memberInboxId: String, to conversationId: String) async throws {
    }

    func removeSuperAdmin(memberInboxId: String, from conversationId: String) async throws {
    }

    func addMembers(inboxIds: [String], to conversationId: String) async throws {
    }

    func removeMembers(inboxIds: [String], from conversationId: String) async throws {
    }

    func getConversationPermissions(for conversationId: String) async throws -> ConversationPermissionPolicySet {
        return ConversationPermissionPolicySet.defaultPolicy
    }

    func getMemberRole(memberInboxId: String, in conversationId: String) async throws -> MemberRole {
        return .member
    }

    func canPerformAction(
        memberInboxId: String,
        action: ConversationPermissionAction,
        in conversationId: String) async throws -> Bool {
        return true
    }

    func getConversationMembers(for conversationId: String) async throws -> [ConversationMemberInfo] {
        return []
    }
}
