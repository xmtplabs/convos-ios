import Combine
import Foundation
import GRDB
import os

public protocol ConversationStateManagerProtocol: AnyObject, DraftConversationWriterProtocol {
    var currentState: ConversationStateMachine.State { get }
    var stateSequence: AsyncStream<ConversationStateMachine.State> { get }

    func resetFromError() async

    var myProfileWriter: any MyProfileWriterProtocol { get }
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

    public let myProfileWriter: any MyProfileWriterProtocol
    public let conversationConsentWriter: any ConversationConsentWriterProtocol
    public let conversationLocalStateWriter: any ConversationLocalStateWriterProtocol
    public let conversationMetadataWriter: any ConversationMetadataWriterProtocol
    public let draftConversationRepository: any DraftConversationRepositoryProtocol

    // MARK: - Private Properties

    private let inboxStateManager: any InboxStateManagerProtocol
    private let stateMachine: ConversationStateMachine

    private var stateObservationTask: Task<Void, Never>?
    private var initializationTask: Task<Void, Never>?

    // MARK: - Initialization

    public init(
        inboxStateManager: any InboxStateManagerProtocol,
        identityStore: any KeychainIdentityStoreProtocol,
        databaseReader: any DatabaseReader,
        databaseWriter: any DatabaseWriter,
        environment: AppEnvironment,
        conversationId: String? = nil,
        backgroundUploadManager: any BackgroundUploadManagerProtocol = UnavailableBackgroundUploadManager()
    ) {
        self.inboxStateManager = inboxStateManager

        let initialConversationId = conversationId ?? DBConversation.generateDraftConversationId()
        self.conversationIdSubject = .init(initialConversationId)

        let inviteWriter = InviteWriter(identityStore: identityStore, databaseWriter: databaseWriter)
        self.conversationMetadataWriter = ConversationMetadataWriter(
            inboxStateManager: inboxStateManager,
            inviteWriter: inviteWriter,
            databaseWriter: databaseWriter
        )

        self.myProfileWriter = MyProfileWriter(
            inboxStateManager: inboxStateManager,
            databaseWriter: databaseWriter
        )

        self.conversationConsentWriter = ConversationConsentWriter(
            inboxStateManager: inboxStateManager,
            databaseWriter: databaseWriter
        )

        self.conversationLocalStateWriter = ConversationLocalStateWriter(
            databaseWriter: databaseWriter
        )

        self.draftConversationRepository = DraftConversationRepository(
            dbReader: databaseReader,
            conversationId: conversationIdSubject.value,
            conversationIdPublisher: conversationIdSubject.eraseToAnyPublisher(),
            inboxStateManager: inboxStateManager
        )

        self.stateMachine = ConversationStateMachine(
            inboxStateManager: inboxStateManager,
            identityStore: identityStore,
            databaseReader: databaseReader,
            databaseWriter: databaseWriter,
            environment: environment,
            clientConversationId: initialConversationId,
            backgroundUploadManager: backgroundUploadManager
        )

        setupStateObservation()

        if let conversationId {
            initializationTask = Task { [stateMachine] in
                await stateMachine.useExisting(conversationId: conversationId)
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
    }

    // MARK: - DraftConversationWriterProtocol Methods

    public func createConversation() async throws {
        await stateMachine.create()
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

    public func send(image: ImageType) async throws {
        try await stateMachine.sendPhoto(image: image)
    }

    public func startEagerUpload(image: ImageType) async throws -> String {
        try await stateMachine.startEagerUpload(image: image)
    }

    public func sendEagerPhoto(trackingKey: String) async throws {
        try await stateMachine.sendEagerPhoto(trackingKey: trackingKey)
    }

    public func cancelEagerUpload(trackingKey: String) async {
        await stateMachine.cancelEagerUpload(trackingKey: trackingKey)
    }

    public func sendVideo(at fileURL: URL, replyToMessageId: String?) async throws -> String {
        try await stateMachine.sendVideo(at: fileURL, replyToMessageId: replyToMessageId)
    }

    public func sendVoiceMemo(at fileURL: URL, duration: TimeInterval, waveformLevels: [Float]? = nil, replyToMessageId: String?) async throws -> String {
        try await stateMachine.sendVoiceMemo(at: fileURL, duration: duration, waveformLevels: waveformLevels, replyToMessageId: replyToMessageId)
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

    public func delete() async throws {
        try await inboxStateManager.deleteInbox()
        await stateMachine.delete()
    }

    public func resetFromError() async {
        await stateMachine.reset()
    }
}
