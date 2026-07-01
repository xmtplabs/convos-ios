import Combine
import ConvosMetrics
import Foundation
import GRDB
import os

public protocol ConversationStateManagerProtocol: AnyObject, DraftConversationWriterProtocol {
    var currentState: ConversationStateMachine.State { get }
    var stateSequence: AsyncStream<ConversationStateMachine.State> { get }

    func resetFromError() async

    var draftConversationRepository: any DraftConversationRepositoryProtocol { get }
    var conversationConsentWriter: any ConversationConsentWriterProtocol { get }
    var conversationLocalStateWriter: any ConversationLocalStateWriterProtocol { get }
    var conversationMetadataWriter: any ConversationMetadataWriterProtocol { get }
}

/// Wraps ConversationStateMachine and provides a dependency container for writers/repositories.
///
/// @unchecked Sendable: State changes are coordinated through ConversationStateMachine actor.
/// Combine subjects are thread-safe for send/subscribe patterns. All async methods delegate
/// to the internal actor.
public final class ConversationStateManager: ConversationStateManagerProtocol, @unchecked Sendable {
    private let stateLock: OSAllocatedUnfairLock<ConversationStateMachine.State> = .init(initialState: .uninitialized)

    public var currentState: ConversationStateMachine.State {
        stateLock.withLock { $0 }
    }

    public var stateSequence: AsyncStream<ConversationStateMachine.State> {
        AsyncStream { [stateMachine] continuation in
            let task = Task {
                for await state in await stateMachine.stateSequence {
                    continuation.yield(state)
                    if Task.isCancelled { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - DraftConversationWriterProtocol Properties

    private let conversationIdSubject: CurrentValueSubject<String, Never>
    private let sentMessageSubject: PassthroughSubject<String, Never> = .init()

    public var conversationId: String {
        conversationIdSubject.value
    }

    public var conversationIdPublisher: AnyPublisher<String, Never> {
        conversationIdSubject.eraseToAnyPublisher()
    }

    public var sentMessage: AnyPublisher<String, Never> {
        sentMessageSubject.eraseToAnyPublisher()
    }

    // MARK: - Dependencies

    public let conversationConsentWriter: any ConversationConsentWriterProtocol
    public let conversationLocalStateWriter: any ConversationLocalStateWriterProtocol
    public let conversationMetadataWriter: any ConversationMetadataWriterProtocol
    public let draftConversationRepository: any DraftConversationRepositoryProtocol

    // MARK: - Private Properties

    private let sessionStateManager: any SessionStateManagerProtocol
    /// Seeds a conversation with the current user's global profile when it
    /// becomes ready. Injected so the concrete implementation
    /// (`ProfilesRepository.publishMyProfileToConversation`) stays out of this
    /// type; defaults to a no-op for tests and mocks.
    private let profileConversationSeeder: @Sendable (String) async -> Void
    private let stateMachine: ConversationStateMachine
    /// Inbox IDs to add to the conversation as part of the initial create
    /// / resume sequence. The contacts picker flow supplies these when
    /// constructing the state manager so they're folded into the same
    /// state-machine action as the conversation creation. Downstream
    /// consumers can then treat `.ready` as the strong guarantee
    /// "conversation exists and these members are in it". Empty preserves
    /// existing "+" button / invite-resume behavior.
    private let initialMemberInboxIds: [String]

    private var stateObservationTask: Task<Void, Never>?
    private var initializationTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(
        sessionStateManager: any SessionStateManagerProtocol,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment,
        conversationId: String? = nil,
        initialMemberInboxIds: [String] = [],
        backgroundUploadManager: any BackgroundUploadManagerProtocol = UnavailableBackgroundUploadManager(),
        coreActions: any CoreActions = NoOpCoreActions(),
        profileConversationSeeder: @escaping @Sendable (String) async -> Void = { _ in }
    ) {
        self.sessionStateManager = sessionStateManager
        self.initialMemberInboxIds = initialMemberInboxIds
        self.profileConversationSeeder = profileConversationSeeder

        let initialConversationId = conversationId ?? DBConversation.generateDraftConversationId()
        self.conversationIdSubject = .init(initialConversationId)

        let inviteWriter = InviteWriter(identityStore: identityStore, databaseWriter: databaseWriter, coreActions: coreActions)
        // Pass the contact-sync coordinator so `addMembers(_:to:)` triggers
        // the membership-change hook and pulls newly added members into
        // the contacts table, matching `MessagingService.conversationMetadataWriter()`.
        let contactSyncCoordinator = ContactSyncCoordinator(
            databaseWriter: databaseWriter,
            databaseReader: databaseReader
        )
        let metadataWriter = ConversationMetadataWriter(
            sessionStateManager: sessionStateManager,
            inviteWriter: inviteWriter,
            databaseWriter: databaseWriter,
            contactSyncCoordinator: contactSyncCoordinator
        )
        self.conversationMetadataWriter = metadataWriter

        self.conversationConsentWriter = ConversationConsentWriter(
            sessionStateManager: sessionStateManager,
            databaseWriter: databaseWriter,
            pushTopicSubscriptionManager: PushTopicSubscriptionManager(
                identityStore: identityStore
            )
        )

        self.conversationLocalStateWriter = ConversationLocalStateWriter(
            databaseWriter: databaseWriter
        )

        self.draftConversationRepository = DraftConversationRepository(
            dbReader: databaseReader,
            conversationId: conversationIdSubject.value,
            conversationIdPublisher: conversationIdSubject.eraseToAnyPublisher(),
            sessionStateManager: sessionStateManager
        )

        // Bridge `ConversationMetadataWriter.addMembers(_:to:)` into the
        // state machine via the hook so the create / useExisting
        // sequences can run it before emitting `.ready`. The metadata
        // writer's full pipeline (XMTP group op, local member rows,
        // contact sync, ProfileSnapshot) is unchanged; it just gets
        // composed into the create sequence atomically.
        let addMembersHook: ConversationStateMachineAddMembersHook = { inboxIds, conversationId in
            try await metadataWriter.addMembers(inboxIds, to: conversationId)
        }

        self.stateMachine = ConversationStateMachine(
            sessionStateManager: sessionStateManager,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            clientConversationId: initialConversationId,
            backgroundUploadManager: backgroundUploadManager,
            addMembersHook: addMembersHook,
            coreActions: coreActions
        )

        setupStateObservation()

        if let conversationId {
            let memberInboxIds = initialMemberInboxIds
            initializationTask = Task { [stateMachine] in
                await stateMachine.useExisting(
                    conversationId: conversationId,
                    initialMemberInboxIds: memberInboxIds
                )
            }
        }
    }

    deinit {
        stateObservationTask?.cancel()
        initializationTask?.cancel()
    }

    private func setupStateObservation() {
        stateObservationTask = Task { [weak self] in
            guard let stateSequence = await self?.stateMachine.stateSequence else { return }

            for await state in stateSequence {
                guard let self else { break }
                await self.handleStateChange(state)
                if Task.isCancelled { break }
            }
        }
    }

    @MainActor
    private func handleStateChange(_ state: ConversationStateMachine.State) {
        stateLock.withLock { $0 = state }

        switch state {
        case .ready(let result),
                .joining(invite: _, placeholder: let result):
            conversationIdSubject.send(result.conversationId)
        default:
            break
        }

        if case .ready(let result) = state {
            scheduleProfileSync(for: result.conversationId)
        }
    }

    private func scheduleProfileSync(for conversationId: String) {
        guard !DBConversation.isDraft(id: conversationId) else { return }
        let seeder = profileConversationSeeder
        Task.detached {
            await seeder(conversationId)
        }
    }

    // MARK: - DraftConversationWriterProtocol Methods

    public func createConversation() async throws {
        try await createConversation(startsUnused: false)
    }

    public func createConversation(startsUnused: Bool) async throws {
        await stateMachine.create(
            initialMemberInboxIds: initialMemberInboxIds,
            startsUnused: startsUnused
        )
    }

    public func joinConversation(inviteCode: String) async throws {
        await stateMachine.join(inviteCode: inviteCode)
    }

    public func send(text: String) async throws {
        await stateMachine.sendMessage(text: text)
        await MainActor.run {
            sentMessageSubject.send(text)
        }
    }

    public func send(text: String, afterPhoto trackingKey: String?) async throws {
        await stateMachine.sendMessage(text: text, afterPhoto: trackingKey)
        await MainActor.run {
            sentMessageSubject.send(text)
        }
    }

    public func send(text: String, clientMessageId: String) async throws {
        await stateMachine.sendMessage(text: text, clientMessageId: clientMessageId)
        await MainActor.run {
            sentMessageSubject.send(text)
        }
    }

    public func send(image: ImageType) async throws {
        try await stateMachine.sendPhoto(image: image)
    }

    public func startEagerUpload(image: ImageType) async throws -> String {
        try await stateMachine.startEagerUpload(image: image)
    }

    public func sendEagerPhoto(trackingKey: String) async throws {
        try await stateMachine.sendEagerPhoto(trackingKey: trackingKey)
    }

    public func startEagerVideoUpload(at fileURL: URL) async throws -> String {
        try await stateMachine.startEagerVideoUpload(at: fileURL)
    }

    public func sendEagerVideo(trackingKey: String) async throws {
        try await stateMachine.sendEagerVideo(trackingKey: trackingKey)
    }

    public func sendEagerVideoReply(trackingKey: String, toMessageWithClientId parentClientMessageId: String) async throws {
        try await stateMachine.sendEagerVideoReply(trackingKey: trackingKey, toMessageWithClientId: parentClientMessageId)
    }

    public func cancelEagerUpload(trackingKey: String) async {
        await stateMachine.cancelEagerUpload(trackingKey: trackingKey)
    }

    public func awaitEagerUpload(trackingKey: String) async throws {
        try await stateMachine.awaitEagerUpload(trackingKey: trackingKey)
    }

    public func sendMultiRemoteAttachment(items: [MultiAttachmentBundleItem]) async throws -> String {
        try await stateMachine.sendMultiRemoteAttachment(items: items)
    }

    public func sendMultiRemoteAttachment(items: [MultiAttachmentBundleItem], clientMessageId: String) async throws -> String {
        try await stateMachine.sendMultiRemoteAttachment(items: items, clientMessageId: clientMessageId)
    }

    public func sendBuilderBundle(
        text: String,
        bundleItems: [MultiAttachmentBundleItem],
        textClientMessageId: String,
        bundleClientMessageId: String,
        awaitsAgentJoin: Bool
    ) async throws {
        try await stateMachine.sendBuilderBundle(
            text: text,
            bundleItems: bundleItems,
            textClientMessageId: textClientMessageId,
            bundleClientMessageId: bundleClientMessageId,
            awaitsAgentJoin: awaitsAgentJoin
        )
    }

    public func sendVideo(at fileURL: URL, replyToMessageId: String?) async throws -> String {
        try await stateMachine.sendVideo(at: fileURL, replyToMessageId: replyToMessageId)
    }

    public func sendVoiceMemo(at fileURL: URL, duration: TimeInterval, waveformLevels: [Float]? = nil, replyToMessageId: String?) async throws -> String {
        try await stateMachine.sendVoiceMemo(at: fileURL, duration: duration, waveformLevels: waveformLevels, replyToMessageId: replyToMessageId)
    }

    public func sendFile(at fileURL: URL, filename: String, mimeType: String, replyToMessageId: String?) async throws -> String {
        try await stateMachine.sendFile(at: fileURL, filename: filename, mimeType: mimeType, replyToMessageId: replyToMessageId)
    }

    public func sendReply(text: String, toMessageWithClientId parentClientMessageId: String) async throws {
        try await stateMachine.sendReply(text: text, toMessageWithClientId: parentClientMessageId)
    }

    public func sendEagerPhotoReply(trackingKey: String, toMessageWithClientId parentClientMessageId: String) async throws {
        try await stateMachine.sendEagerPhotoReply(trackingKey: trackingKey, toMessageWithClientId: parentClientMessageId)
    }

    public func sendReply(text: String, afterPhoto trackingKey: String?, toMessageWithClientId parentClientMessageId: String) async throws {
        try await stateMachine.sendReply(text: text, afterPhoto: trackingKey, toMessageWithClientId: parentClientMessageId)
    }

    public func retryFailedMessage(id: String) async throws {
        try await stateMachine.retryFailedMessage(id: id)
    }

    public func deleteFailedMessage(id: String) async throws {
        try await stateMachine.deleteFailedMessage(id: id)
    }

    public func insertPendingInvite(text: String) async throws -> String {
        try await stateMachine.insertPendingInvite(text: text)
    }

    public func finalizeInvite(clientMessageId: String, finalText: String) async throws {
        try await stateMachine.finalizeInvite(clientMessageId: clientMessageId, finalText: finalText)
    }

    public func resetFromError() async {
        await stateMachine.reset()
    }
}
